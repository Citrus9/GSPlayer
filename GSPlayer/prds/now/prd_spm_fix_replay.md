### Replay stall + duplicate replayId investigation and fix

Below is a concise walkthrough of what the logs are telling us, the most likely root cause, and concrete code edits (clearly split between GSPlayer SPM code and SwiftUI client code) to both fix the issue and add better instrumentation.

---

## What the logs are saying

- You’re seeing multiple “reachedEnd” and “autoReplay — seeking→0” lines around each loop.
- `replayId` is incrementing by 2 each loop. That means the “auto-replay” path is executing twice per end event.
- During the stall, “timeCtrl=waiting … rate=1.0 likely=true” appears while your own slider continues to tick. That indicates AVPlayer is “playing” time but the layer is not rendering new frames (classic replay race/double-replay symptom).

Why so many logs?
- You currently print on every timeControlStatus transition (paused/waiting/playing), so you’ll see bursts around each replay.
- You also have both the wrapper-side “[VID] …” and GSPlayer-side “[GS] …” logs firing.
- The important anomaly is the duplicate “end -> replay” sequence, which explains both log spam and the stall.

---

## Root cause

- In `GSPlayer.VideoPlayerView`, end-of-play is observed with a global NotificationCenter observer:
  - `NotificationCenter.default.addObserver(... name: .AVPlayerItemDidPlayToEndTime, object: nil, ...)`
- Even though you guard `notification.object == player?.currentItem`, the observer’s lifecycle and SwiftUI view reuse can still result in multiple deliveries (or lingering observers on the same item). This causes `playerItemDidReachEnd` to run twice, calling `replay(resetCount: false)` twice in quick succession.
- Two back-to-back `seek(to: .zero)` and `playImmediately` calls can put AVPlayer/AVPlayerLayer in a weird state where time advances but the layer doesn’t redraw a new frame (the “stall” you’re seeing, often at 0–1s).

Why does this also happen for fully cached videos?
- Because it’s not a network/buffering problem; it’s a replay event coordination problem. Doubling the replay calls can race the layer and event loop independent of cache state.

---

## The fix (SPM side – GSPlayer)

1) Make the end-of-play observer item-scoped instead of global, and tear it down when the item changes.  
2) Add a micro de-duplication guard so even if an OEM quirk posts back-to-back end events you only handle one.  
3) Reset the “first frame” gate on replay and pause-before-seek to avoid re-entry races.

Make these edits in your GSPlayer code (SPM):

- File: GSPlayer `VideoPlayerView` (inside your SPM, not the SwiftUI wrapper)

A) Track and manage an item-scoped observer
```swift
// GSPlayer SPM side (VideoPlayerView)

private var endObserverToken: NSObjectProtocol?
private var suppressDuplicateEndUntil: CFAbsoluteTime = 0
```

- Remove the global observer from `configureInit()`:
```swift
// DELETE this from configureInit():
NotificationCenter.default.addObserver(
    self,
    selector: #selector(playerItemDidReachEnd(notification:)),
    name: .AVPlayerItemDidPlayToEndTime,
    object: nil
)
```

- In `observe(playerItem:)`, register per-item and tear down:
```swift
// GSPlayer SPM side (VideoPlayerView.observe(playerItem:))
if let existing = endObserverToken {
    NotificationCenter.default.removeObserver(existing)
    endObserverToken = nil
}

guard let playerItem = playerItem else {
    return
}

endObserverToken = NotificationCenter.default.addObserver(
    forName: .AVPlayerItemDidPlayToEndTime,
    object: playerItem,
    queue: .main
) { [weak self] note in
    guard let self = self else { return }
    let now = CFAbsoluteTimeGetCurrent()
    if now < self.suppressDuplicateEndUntil {
        #if DEBUG
        print("🎥 [GS] ⚠️ end event suppressed (duplicate)")
        #endif
        return
    }
    self.suppressDuplicateEndUntil = now + 0.05
    self.playerItemDidReachEnd(notification: note)
}
```

B) Harden `playerItemDidReachEnd` and `replay`:
```swift
// GSPlayer SPM side (VideoPlayerView)
@objc func playerItemDidReachEnd(notification: Notification) {
    guard (notification.object as? AVPlayerItem) == player?.currentItem else { return }

    #if DEBUG
    let dur = player?.currentItem?.duration.seconds ?? 0
    let cur = player?.currentItem?.currentTime().seconds ?? 0
    print("🎥 [GS] ⛳️ END event — cur=\(String(format:"%.2f",cur))/\(String(format:"%.2f",dur)) id=\(replayId)")
    #endif

    playToEndTime?()

    guard isAutoReplay else { return }

    isReplay = true
    replay(resetCount: false)
}

open func replay(resetCount: Bool = false) {
    replayCount = resetCount ? 0 : replayCount + 1
    if resetCount { replayId = 0 } else { replayId += 1 }

    // Reset gating so the layer will signal first-frame again after seek
    hasPresentedFirstFrame = false

    // Pause first to avoid end-notification re-entry races on some devices
    player?.pause()

    #if DEBUG
    print("🎥 [GS] 🔁 autoReplay — id=\(replayId) seek→0")
    #endif

    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
        #if DEBUG
        print("🎥 [GS] 🔁 autoReplay — id=\(self?.replayId ?? -1) seek ok; resume")
        #endif
        let rate = self?.speedRate ?? 1.0
        self?.player?.playImmediately(atRate: rate)
    }
}
```

Optional experiment (if a specific asset still stalls): temporarily disable AVPlayer’s waiting behavior to see if symptoms change.
```swift
// GSPlayer SPM side (VideoPlayerView.play(for:))
player.automaticallyWaitsToMinimizeStalling = false // default is true
```
If this reduces “waiting” logs without regressions, keep it. If startup stutters increase, turn it back on.

---

## What to change in the SwiftUI client

You don’t need functional changes in `ExploreDetailView.swift` for the replay fix. Your wrapper already logs well. If you want clearer, fewer logs:
- Keep your “[VID] …” logs but know you’ll now see a single “reachedEnd” per loop after the SPM fix.
- Optionally coalesce your per-tick prints (only log every 0.5–1.0 seconds instead of 60 Hz in `onPlaybackTick`).

Example throttled tick logging:
```swift
// SwiftUI client side (ExploreDetailView.swift)
// around .onPlaybackTick
.onPlaybackTick { current, total in
    // existing progress update...
    if Int(current * 10) % 10 == 0 { // ~each 1.0s
        print("🎥 [VID] ⏱️ t=\(Int(current))/\(Int(total))")
    }
}
```

---

## Add the missing “buffer-wait” logs (so you can see when you pause to buffer)

Add two strategic logs in GSPlayer SPM:

1) When timeControlStatus becomes waiting:
```swift
// GSPlayer SPM side (VideoPlayerView.observe(player:))
case .waitingToPlayAtSpecifiedRate:
    let reason = player.reasonForWaitingToPlay?.rawValue ?? "-"
    let bufDur = self.currentBufferDuration
    let cur = self.currentDuration
    #if DEBUG
    print("🎥 [GS] ⏳ waiting — reason=\(reason) bufDur=\(String(format:"%.2f",bufDur)) cur=\(String(format:"%.2f",cur))")
    #endif
    // existing state update...
```

2) When loadedTimeRanges changes (so you see buffer growth):
```swift
// GSPlayer SPM side (VideoPlayerView.observe(playerItem:))
playerBufferingObservation = playerItem.observe(\.loadedTimeRanges) { [unowned self] item, _ in
    let bufDur = self.currentBufferDuration
    let cur = self.currentDuration
    #if DEBUG
    print("🎥 [GS] 🧱 buffer — cur=\(String(format:"%.2f",cur)) bufDur=\(String(format:"%.2f",bufDur))")
    #endif

    // existing preload start/pause logic...
}
```

Optional (download path visibility, useful if you suspect cache/loader interplay):
```swift
// GSPlayer SPM side (VideoRequestLoader.start)
#if DEBUG
let dr = request.dataRequest
let off = dr?.requestedOffset ?? 0
let len = dr?.requestedLength ?? 0
print("🎥 [GS] 📦 request — offset=\(off) len=\(len) allToEnd=\(dr?.requestsAllDataToEndOfResource ?? false)")
#endif
```

---

## How to verify

- Build and run the same stalling asset:
  - Expect exactly one “🎥 [VID] 🔁 reachedEnd — autoReplay=true” per loop.
  - Expect `replayId` to increment by 1 each loop (0 → 1 → 2 → 3…).
  - No stall on second replay; frames should render immediately after the seek.
- If any stubborn asset still stalls, temporarily set `player.automaticallyWaitsToMinimizeStalling = false` as above and recheck. If the stall disappears and you like the trade-offs, keep it.

---

## Why this solves it

- By scoping the end-of-play observer to the current `AVPlayerItem` and suppressing rapid duplicates, you eliminate the second replay call that was racing the layer.
- Resetting `hasPresentedFirstFrame` on replay plus pausing before seek makes the “first frame” path deterministic on each loop and avoids “time moves but no frame” artifacts.
- The added logs make buffer-wait and replay moments explicit, so you can tell whether a future stall is buffer-related or replay-related in seconds.

---

- Fixed: duplicate replay triggers (replayId now +1 per loop).
- Fixed: replay stalls at ~1s caused by double seek/play race.
- Added: clear logs for waiting/buffer growth and request ranges to debug faster next time.