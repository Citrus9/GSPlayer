### PRD: Correct buffering pause behavior, prevent false “playing”, and expose pause reasons to SwiftUI

#### Author
ViralGen iOS

#### Context
Playback in `ExploreDetailView` uses our SwiftUI wrapper `VideoPlayer.swift` which embeds the SPM `GSPlayer` implementation (`PRD/projectStructure/GSPlayer.md`). After refactors, when buffering kicks in, AVPlayer correctly pauses to wait, but the UI immediately flips to a “playing” state and the seek bar continues to advance.

You also want SwiftUI to know why a video is paused (buffering vs user) so you can:
- show a loading indicator while buffering
- show a pause icon for user-initiated pause
- prevent the user from resuming when the pause is due to buffering

---

### Problem statement

- Logs show: waiting → paused → immediately “playing”, even when `isPlaybackLikelyToKeepUp=false`.

Observed:
- `🎥 [GS] ⏳ timeCtrl=waiting reason=AVPlayerWaitingToMinimizeStallsReason …`
- `🎥 [VID] ⏸ paused …`
- `🎥 [GS] 🎬 paused …`
- then instantly:
- `🎥 [VID] ▶️ playing …`
- `🎥 [GS] 🎬 playing …`

This makes the seek bar tick while the actual video is stalled.

---

### Root cause

1) SwiftUI wrapper (VideoPlayer.updateUIView) forces resume repeatedly:
```124:165:ViralGen/Utils/VideoPlayer.swift
if play {
    if uiView.playerURL == url {
        context.coordinator.didFireFirstFrameReady = false
        uiView.resume() // forces playImmediately on each SwiftUI update
    } else {
        context.coordinator.didFireFirstFrameReady = false
        uiView.play(for: url)
    }
} else {
    uiView.pause(reason: .userInteraction)
}
```
This fight against AVPlayer’s buffering toggles `timeControlStatus` to `.playing` briefly, even when it can’t keep up yet.

2) Player observer promotes to “playing” without checking keep-up:
```2608:2653:PRD/projectStructure/GSPlayer.md
case .playing:
    if self.playerLayer.isReadyForDisplay, player.timeControlStatus == .playing {
        if !self.hasPresentedFirstFrame { ... }
        self.isLoaded = true
        self.state = .playing // promotes even if likelyToKeepUp == false
    }
```

Result: the wrapper broadcasts “playing” and the UI’s high-rate tick continues, even though the player is still stalling.

---

### Goals

- Prevent “paused → playing” flaps during buffering.
- Expose pause reason (user vs buffering) to SwiftUI.
- Enable UI to show buffering progress and disallow resume while buffering.

Non-goals:
- Changing overall caching/prefetch architecture.
- Adding new dependencies.

---

### Proposed design

#### A) GSPlayer (SPM) side changes

1) Gate “playing” on ability to keep up
- Only set `.playing` when `isPlaybackLikelyToKeepUp == true`.
- If not ready, treat as `.paused(.waitingKeepUp)` or `.loading` until first frame is presented.

Suggested change in `VideoPlayerView` timeControl observer:
```swift
// PRD/projectStructure/GSPlayer.md (inside playerTimeControlStatusObservation)
case .playing:
    if self.playerLayer.isReadyForDisplay, player.timeControlStatus == .playing {

        // New: must be ready to keep up before promoting to playing
        let likely = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
        if !likely {
            if self.hasPresentedFirstFrame {
                self.state = .paused(playProgress: self.playProgress, bufferProgress: self.bufferProgress)
            } else {
                self.state = .loading
            }
            return
        }

        if !self.hasPresentedFirstFrame {
            self.hasPresentedFirstFrame = true
            self.firstFrameReady?()
        }
        self.isLoaded = true
        if self.playProgress == 0, self.isReplay { self.isReplay = false }
        self.state = .playing
    }
```

2) Make resume buffering-friendly
- Use `player?.play()` (respects buffering) instead of `playImmediately(atRate:)` (which can fake “playing”).
```swift
// PRD/projectStructure/GSPlayer.md (in VideoPlayerView.resume)
open func resume() {
    pausedReason = .waitingKeepUp
    player?.play() // instead of playImmediately(atRate:)
}
```
- If you need custom rate, set `speedRate` and allow it to take effect once `.playing` is achieved.

3) Carry pause reason through the SwiftUI wrapper
- The underlying `VideoPlayerView` already tracks `pausedReason: .hidden | .userInteraction | .waitingKeepUp`.
- We will propagate this reason to the SwiftUI `VideoPlayer.State`.

Change mapping in the wrapper’s `convertState()`:
```418:429:ViralGen/Utils/VideoPlayer.swift
private extension VideoPlayerView {
    func convertState() -> VideoPlayer.State {
        switch state {
        case .none, .loading:
            return .loading
        case .playing:
            return .playing(totalDuration: totalDuration)
        case .paused(let p, let b):
            // NEW: pass the reason
            return .paused(reason: self.pausedReason, playProgress: p, bufferProgress: b)
        case .error(let error):
            return .error(error)
        }
    }
}
```

And update the `VideoPlayer.State` enum to carry the reason:
```swift
// ViralGen/Utils/VideoPlayer.swift
enum State {
    case loading
    case playing(totalDuration: Double)
    case paused(reason: VideoPlayerView.PausedReason, playProgress: Double, bufferProgress: Double)
    case error(NSError)
}
```

This is a controlled source change (wrapper and app are ours). If you prefer non-breaking, see the “Non-breaking alternative” at the end.

#### B) SwiftUI wrapper changes (`VideoPlayer.updateUIView`)

- Only call `resume()` in two situations:
  1) The user explicitly toggled play from false → true (actual intent).
  2) The previous pause reason was `.userInteraction`.

- Never “resume” when we are stalled/buffering (`pausedReason == .waitingKeepUp`). Let AVPlayer resume when it can keep up.

Implementation outline:
```swift
// ViralGen/Utils/VideoPlayer.swift
@MainActor
class Coordinator: NSObject {
    var videoPlayer: VideoPlayer
    var observingURL: URL?
    var lastRequestedPlay: Bool = false // NEW: track play intent
    ...
}

func updateUIView(_ uiView: VideoPlayerView, context: Context) {
    // Reset observers if URL changed (existing)
    if context.coordinator.observingURL != url { ... }

    // NEW: detect intent change
    let intentChangedToPlay = (context.coordinator.lastRequestedPlay == false && play == true)
    context.coordinator.lastRequestedPlay = play

    if play {
        if uiView.playerURL == url {
            // Only resume if user intent changed to play OR last pause was user-initiated
            if intentChangedToPlay || uiView.pausedReason == .userInteraction {
                context.coordinator.didFireFirstFrameReady = false
                uiView.resume() // now uses player?.play()
            }
            // else: buffering → do not force resume; AVPlayer will resume itself
        } else {
            context.coordinator.didFireFirstFrameReady = false
            uiView.play(for: url)
        }
    } else {
        uiView.pause(reason: .userInteraction)
    }

    uiView.isMuted = config.mute
    uiView.isAutoReplay = config.autoReplay
    uiView.speedRate = config.speedRate
    ...
}
```

Result: no more “false playing” logs while buffering; the UI won’t get spurious “playing” state and the seek bar won’t advance.

---

### SwiftUI consumption and UI behavior

We will expose pause reason via the existing `onStateChanged` callback using the new paused variant. This makes it trivial to drive UI state.

Example in `ExploreDetailView`:
```swift
// ViralGen/VideoGen/Views/Explore/ExploreDetailView.swift (inside videoPlayer(url:))
VideoPlayer(url: url, play: $play, time: $time)
    .autoReplay(true)
    .mute(false)
    .contentMode(.scaleAspectFit)
    .onPlaybackTick { current, total in
        guard total > 0 else { playbackProgress = 0; return }
        playbackProgress = min(1, max(0, current / total))
    }
    .onBufferChanged { progress in
        bufferProgress = min(1, max(0, progress))
    }
    .onStateChanged { state in
        switch state {
        case .loading:
            isBuffering = true
            pausedByUser = false
        case .playing:
            isBuffering = false
            pausedByUser = false
        case .paused(let reason, _, _):
            // Drive UI according to reason:
            isBuffering = (reason == .waitingKeepUp)
            pausedByUser = (reason == .userInteraction)
        case .error:
            isBuffering = false
            pausedByUser = false
        }
    }
```

Now you can:
- Show a spinner or progress bar when `isBuffering == true`.
- Show a pause icon when `pausedByUser == true`.
- Disable user “resume” action while `isBuffering == true` (since AVPlayer will resume automatically).
- Continue using your `AdvancedInstagramControls` with accurate pause/play feedback; just gate resume on `!isBuffering`.

Simple gating in controls:
```swift
// ViralGen/Utils/AdvancedInstagramControls.swift (conceptual usage)
.onTapGesture {
    if !isBuffering { // from parent environment/state
        play.toggle()
    }
}
```

---

### End-to-end behavior after changes

- When the buffer runs out:
  - AVPlayer transitions to `.waitingToPlayAtSpecifiedRate`
  - `VideoPlayerView` sets state to `.paused(.waitingKeepUp, …)` or `.loading` (no false “playing”)
  - `onStateChanged` lets SwiftUI set `isBuffering = true` and show the spinner/progress bar
  - The wrapper no longer forces `resume()`, so no spurious `playing` log/output
- Once enough data is buffered:
  - `isPlaybackLikelyToKeepUp == true` → observer promotes to `.playing`
  - `onStateChanged` sets `isBuffering = false`, hides spinner, the seek bar ticks again

---

### Code changes summary (what and where)

- GSPlayer (SPM) side:
  - Gate “playing” on `isPlaybackLikelyToKeepUp`.
  - Make `resume()` use `player?.play()` instead of `playImmediately(atRate:)`.

- SwiftUI wrapper side (`VideoPlayer.swift`):
  - Expand `VideoPlayer.State.paused` to include `reason`.
  - In `convertState()`, pass `self.pausedReason` into `.paused`.
  - In `updateUIView`, only call `resume()` on user intent change or when last pause reason was `.userInteraction`. Track last requested play in `Coordinator`.

- SwiftUI usage (`ExploreDetailView`):
  - React to `onStateChanged` to set `isBuffering` and `pausedByUser`.
  - Show a spinner/progress bar on `isBuffering`.
  - Disable resume while buffering.

---

### Testing plan

- Scenario A: Start playback on a slow connection
  - Expect: `.loading` → `.paused(.waitingKeepUp, …)` (spinner visible) → after buffer fills, `.playing` (spinner hidden)
  - No “playing” prints while `likelyToKeepUp=false`.

- Scenario B: User taps pause while playing
  - Expect: `.paused(.userInteraction, …)`; resume allowed by tapping play.

- Scenario C: Buffer depletion mid‑play
  - Expect: `.paused(.waitingKeepUp, …)`; UI blocks resume; progress bar shows growth; eventually `.playing`.

- Logs sanity:
  - No immediate “▶️ playing” logs after “⏳ waiting … likely=false”.

---

### Non-breaking alternative (if you don’t want to change `VideoPlayer.State` signature)

If you prefer not to change the `State.paused` case:
- Keep `State` as is.
- Add a new callback `onPausedWithReason: (VideoPlayerView.PausedReason, Double, Double) -> Void`.
- Or add `onStateChangedDetailed: (VideoPlayer.State, VideoPlayerView.PausedReason?) -> Void`.
- Still apply the resume gating and playing gate fixes.

This is slightly less elegant but avoids a source-breaking enum change.

---

### Appendix: Why “play()” vs “playImmediately(atRate:)”
- `play()` respects AVPlayer’s stalling avoidance and keeps `timeControlStatus` at `.waitingToPlayAtSpecifiedRate` until ready.
- `playImmediately(atRate:)` pushes `.playing` even when buffering cannot sustain playback yet, causing the false “playing” blip.

---

### Implementation snippets (ready to paste)

- Wrap state enum (SwiftUI wrapper):
```swift
// ViralGen/Utils/VideoPlayer.swift
enum State {
    case loading
    case playing(totalDuration: Double)
    case paused(reason: VideoPlayerView.PausedReason, playProgress: Double, bufferProgress: Double)
    case error(NSError)
}
```

- State mapping:
```swift
// ViralGen/Utils/VideoPlayer.swift
private extension VideoPlayerView {
    func convertState() -> VideoPlayer.State {
        switch state {
        case .none, .loading: return .loading
        case .playing: return .playing(totalDuration: totalDuration)
        case .paused(let p, let b): return .paused(reason: self.pausedReason, playProgress: p, bufferProgress: b)
        case .error(let e): return .error(e)
        }
    }
}
```

- Resume gating:
```swift
// ViralGen/Utils/VideoPlayer.swift (Coordinator + updateUIView changes)
class Coordinator: NSObject {
    var lastRequestedPlay: Bool = false
    ...
}

func updateUIView(_ uiView: VideoPlayerView, context: Context) {
    let intentChangedToPlay = (context.coordinator.lastRequestedPlay == false && play == true)
    context.coordinator.lastRequestedPlay = play

    if play {
        if uiView.playerURL == url {
            if intentChangedToPlay || uiView.pausedReason == .userInteraction {
                context.coordinator.didFireFirstFrameReady = false
                uiView.resume()
            }
        } else {
            context.coordinator.didFireFirstFrameReady = false
            uiView.play(for: url)
        }
    } else {
        uiView.pause(reason: .userInteraction)
    }
    ...
}
```

- Gate “playing” on keep-up:
```swift
// PRD/projectStructure/GSPlayer.md (timeControl observer)
case .playing:
    if self.playerLayer.isReadyForDisplay, player.timeControlStatus == .playing {
        let likely = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
        if !likely {
            if self.hasPresentedFirstFrame {
                self.state = .paused(playProgress: self.playProgress, bufferProgress: self.bufferProgress)
            } else {
                self.state = .loading
            }
            return
        }
        ...
        self.state = .playing
    }
```

- Resume uses `play()`:
```swift
// PRD/projectStructure/GSPlayer.md
open func resume() {
    pausedReason = .waitingKeepUp
    player?.play()
}
```

- SwiftUI state wiring:
```swift
// ViralGen/VideoGen/Views/Explore/ExploreDetailView.swift
@State private var isBuffering = false
@State private var pausedByUser = false

VideoPlayer(url: url, play: $play, time: $time)
    ...
    .onStateChanged { state in
        switch state {
        case .loading:
            isBuffering = true; pausedByUser = false
        case .playing:
            isBuffering = false; pausedByUser = false
        case .paused(let reason, _, _):
            isBuffering = (reason == .waitingKeepUp)
            pausedByUser = (reason == .userInteraction)
        case .error:
            isBuffering = false; pausedByUser = false
        }
    }
```

---

- Fixing these two areas eliminates the “false playing” blip and cleanly surfaces pause reasons to SwiftUI for proper UI/UX around buffering and user control.
