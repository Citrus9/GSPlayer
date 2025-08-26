### What changed, and why this video now “never resumes”

- The new “don’t fight AVPlayer” gating stopped calling `resume()` while the pause reason is buffering (`.waitingKeepUp`). We rely on AVPlayer’s auto-resume (via `automaticallyWaitsToMinimizeStalling` and `isPlaybackLikelyToKeepUp`).
- On this large MP4, AVFoundation stays in `.waitingToMinimizeStalls` with `likely=false` even after many bytes are locally available (we see “actions — local … remote=0”). That means the “keep-up” signal never flips back to true, so AVPlayer does not auto-resume. Since our wrapper now avoids calling `resume()` when buffering, playback can get stuck in a wait loop.
- The repeated “not resuming” logs are expected: SwiftUI re-runs `updateUIView` frequently; with `play==true`, `state != .playing`, and reason `.waitingKeepUp`, we print the guard log each time.

In short: the new gating removed our explicit resume “nudge,” and AVPlayer didn’t emit the “ready to keep up” signal for this file, so playback waited forever.

### Minimal fix: Allow resume when enough buffer is available (throttled)

Keep the no-thrash rule, but add a safe “resume when we truly have enough buffered headroom” path. This preserves the original intent (don’t spam resume) and unblocks assets that never flip `likely=true`.

SwiftUI wrapper change (in `ViralGen/Utils/VideoPlayer.swift`, `updateUIView`):

- Compute buffer headroom: `bufferAhead = uiView.currentBufferDuration - uiView.currentDuration`.
- If paused reason is `.waitingKeepUp` AND `bufferAhead >= resumeThreshold` (e.g., 0.75–1.0s) then call `uiView.resume()`, throttled (e.g., at most once per 0.5s).
- Continue to resume on user intent change and `.hidden` as you already implemented.

Example:

```swift
// Add to Coordinator
var lastResumeAttemptAt: CFAbsoluteTime = 0

// In updateUIView
let intentChangedToPlay = (context.coordinator.lastRequestedPlay == false && play == true)
context.coordinator.lastRequestedPlay = play

if play {
    if uiView.playerURL == url {
        if uiView.state != .playing {
            let reason = uiView.pausedReason
            let bufferAhead = uiView.currentBufferDuration - uiView.currentDuration
            let resumeThreshold: Double = 0.8     // tune 0.6–1.0
            let now = CFAbsoluteTimeGetCurrent()
            let canThrottle = (now - context.coordinator.lastResumeAttemptAt) > 0.5

            if intentChangedToPlay
                || reason == .userInteraction
                || reason == .hidden
                || (reason == .waitingKeepUp && bufferAhead >= resumeThreshold && canThrottle) {

                context.coordinator.didFireFirstFrameReady = false
                uiView.resume()                   // uses player?.play()
                context.coordinator.lastResumeAttemptAt = now
            } else {
                print("🎥 [VID] 🔁 updateUIView — not resuming — \(url.lastPathComponent) intent=\(intentChangedToPlay) reason=\(reason) state=\(uiView.state) bufAhead=\(String(format: "%.2f", bufferAhead))")
            }
        }
    } else {
        context.coordinator.didFireFirstFrameReady = false
        uiView.play(for: url)
    }
} else {
    uiView.pause(reason: .userInteraction)
}
```

Why this works:
- We still avoid calling resume blindly.
- If AVPlayer doesn’t flip `likely=true`, but we can see ≥0.8s headroom, we give it a gentle `play()` nudge.
- Throttling prevents log spam and oscillation.

### Optional hardening on the SPM (GSPlayer) side

- When `isPlaybackLikelyToKeepUp` KVO flips to true, resume with `play()` (buffer-aware) instead of `playImmediately(atRate:)`:
```swift
// PRD/projectStructure/GSPlayer.md
if item.isPlaybackLikelyToKeepUp {
    if self.player?.rate == 0, self.pausedReason == .waitingKeepUp {
        self.player?.play()
    }
}
```

- Keep the “gate .playing on likelyToKeepUp” guard (prevents false playing), but if you see long waits on some assets, also allow promotion to `.playing` when `bufferAhead >= resumeThreshold` even if `likely==false`:
```swift
let likely = player.currentItem?.isPlaybackLikelyToKeepUp ?? false
let bufferAhead = self.currentBufferDuration - self.currentDuration
if !likely && bufferAhead < 0.8 {
    // stay loading/paused
    ...
    return
}
// else promote to .playing
```

### Why the seek bar looked alive while the picture didn’t move
Brief transitions to `.playing` (or periodic time observer still attached) can advance the time while the layer hasn’t drawn frames. Gating `.playing` and the observer on true keep-up and/or sufficient buffer ahead removes that illusion.

### If it still sticks on this file
- Temporarily pause sustained prefetch for the same URL while it’s “waitingKeepUp” to reduce any contention:
```swift
// when waitingKeepUp for current URL:
await VideoDownloadManager.shared.pause(url: url)
// resume when .playing:
await VideoDownloadManager.shared.resume(url: url)
```
- As a last resort, reuse your existing retry path (invalidate loader + brief prewarm) if stuck in waiting for > N seconds:
```swift
// if waitingKeepUp persists > 3s and bufferAhead stays ~0:
VideoLoadManager.shared.invalidate(url: url)
await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0)
await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: 1_048_576, priority: 1.0)
```

### TL;DR
- Nothing “broke” in downloads; our new gating removed an explicit resume nudge. This large MP4 never flips `likely=true`, so AVPlayer doesn’t auto-resume.
- Add a safe resume condition: if bufferAhead ≥ ~0.8s, call `resume()` (throttled). Keep the rest of the guards.
- Optionally, make the SPM resume on `isPlaybackLikelyToKeepUp` with `play()` and allow `.playing` when bufferAhead is sufficient even if `likely` doesn’t flip.