### PRD: Simple single-variable auto-replay (loop) architecture

#### Goal
- Control looping with a single variable (no external replay hook): set `isAutoReplay` and have seamless, reliable looping without duplicate seeks or stalls.

#### Background
- Current GSPlayer-based flow exposes both an internal auto-replay path and an external `replay` callback. When both are active, two seeks may be issued at end-of-play, causing `seek(to:) ok=false` on one path and a replay stall.
- We want clear ownership: GSPlayer handles auto-replay when enabled; SwiftUI does not issue its own replay.

---

### Design
- **Single source of truth**: `VideoPlayerView.isAutoReplay: Bool` governs looping.
- **Ownership**:
  - If `isAutoReplay == true`: GSPlayer performs replay internally (zero-tolerance seek-to-zero, then `playImmediately`). No external replay callback is invoked.
  - If `isAutoReplay == false`: GSPlayer does not auto-replay; it emits `playToEndTime?()` so UI can decide what to do; the `replay` callback (if provided) is reserved for manual/UX-driven replays.
- **Eventing**:
  - At loop start, ensure `.playing` is emitted so observers re-attach (remove the early `break` that suppresses `.playing` during replay).

---

### Implementation

#### GSPlayer side (in `PRD/projectStructure/GSPlayer.md`)

1) Emit `.playing` on loop start
```swift
// In VideoPlayerView.observe(player:)
playerTimeControlStatusObservation = player.observe(\.timeControlStatus) { [unowned self] player, _ in
    switch player.timeControlStatus {
    case .paused:
        guard !self.isReplay else { break }
        self.state = .paused(playProgress: self.playProgress, bufferProgress: self.bufferProgress)
    case .waitingToPlayAtSpecifiedRate:
        self.state = .paused(playProgress: self.playProgress, bufferProgress: self.bufferProgress)
    case .playing:
        if self.playerLayer.isReadyForDisplay, player.rate > 0 {
            self.isLoaded = true
            if self.playProgress == 0, self.isReplay { self.isReplay = false /* remove prior break */ }
            self.state = .playing
        }
    @unknown default: break
    }
}
```

2) Single-path auto-replay ownership
```swift
// In VideoPlayerView.playerItemDidReachEnd(...)
playToEndTime?()
guard isAutoReplay else { return }
isReplay = true
replay(resetCount: false) // internal path only; do NOT invoke external replay callback here
```

3) Make internal replay robust (zero-tolerance seek)
```swift
// In VideoPlayerView.replay(resetCount:)
replayCount = resetCount ? 0 : replayCount + 1
player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
    self?.player?.playImmediately(atRate: self?.speedRate ?? 1.0)
}
```

4) Optional (future): when fully cached, consider local file + AVPlayerLooper
```swift
// Detect fully cached and switch to local file + AVQueuePlayer + AVPlayerLooper internally
// (Requires changing player to AVQueuePlayer when looper is active; can be a later enhancement.)
```

#### SwiftUI side (in `ViralGen/Utils/VideoPlayer.swift`)

1) Do not assign a custom `uiView.replay` closure
```swift
// Remove this external hook:
// uiView.replay = { [unowned uiView] in
//     uiView.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { ... }
// }
```

2) Configure looping purely via `autoReplay(true/false)`
```swift
VideoPlayer(url: url, play: $play, time: $time)
    .autoReplay(true)     // or .autoReplay(false)
    .onPlayToEndTime {    // optional UI reaction; no seek here
        // update UI, analytics, haptics
    }
```

3) Keep state observation as-is (it will re-emit `.playing` on loop start)
```swift
uiView.stateDidChanged = { [unowned uiView] _ in
    let state: State = uiView.convertState()
    if case .playing = state { context.coordinator.startObserver(uiView: uiView) }
    else { context.coordinator.stopObserver(uiView: uiView) }
    DispatchQueue.main.async { self.config.handler.onStateChanged?(state) }
}
```

---

### Diagnostics (during rollout)
- Add a one-time guard log if `playerItemDidReachEnd` fires twice within 50 ms, and if both `isAutoReplay` and an external `replay` closure are present (should not happen after changes).
- Log seek completion on replay (expect `ok=true`). If `ok=false`, verify only one seek is being issued and no other `.replaceCurrentItem` happens concurrently.

```swift
#if DEBUG
print("🎥 [GS] 🔁 autoReplay — seeking→0")
// After completion
print("🎥 [GS] 🔁 autoReplay — seek ok=true; resuming")
#endif
```

---

### Acceptance criteria
- With `isAutoReplay = true`, videos loop without stalls; replay seeks complete (`ok=true`), `.playing` is emitted at each loop start, and UI observers stay attached.
- With `isAutoReplay = false`, video stops at end, no auto seek occurs, and `playToEndTime` is invoked for UI logic.
- No duplicate replay seeks occur; no external replay path is needed to achieve looping.

---

### Summary of changes
- **GSPlayer**: Own the auto-replay path when enabled; zero‑tolerance seek; ensure `.playing` is emitted; do not call external `replay` during auto mode.
- **SwiftUI**: Do not implement replay; configure via `.autoReplay(true/false)` and observe state/end for UI only.


