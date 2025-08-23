### TL;DR
- GSPlayer side: emit `.playing` at the start of each loop; and correct `contentLength` when a more authoritative value arrives (so 100% is achievable).
- SwiftUI side: your observer will then re‑attach automatically on replay; in the grid, render 100% using a boolean “complete” check instead of raw ratio alone.

### GSPlayer (SPM) changes

1) Make replay emit `.playing` so observers re-attach on every loop
- Current code suppresses `.playing` right when replay starts, so your SwiftUI wrapper never restarts its periodic time observer after the first loop.
```2568:2587:PRD/projectStructure/GSPlayer.md
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
            if self.playProgress == 0, self.isReplay { self.isReplay = false; break }   // <- remove the break
            self.state = .playing
        }
```
- Change: remove the `break` (keep `isReplay = false`) so `.playing` fires at loop start.

2) Update `contentLength` when a better value arrives
- Some servers first respond without a definitive total, then later provide it. Your code only sets `info` when it’s currently `nil`, which can lock in a too-small total and cap the UI at 98–99%.
```520:572:PRD/projectStructure/GSPlayer.md
func handler(_ handler: VideoDownloaderHandler, didReceive response: URLResponse) {
    if info == nil, let httpResponse = response as? HTTPURLResponse {   // <- widen this condition
        ...
        let contentLength = lengthFromRangeTotal
            ?? lengthFromHeader
            ?? lengthFromExpected
            ?? lengthFromRangeLowerBound
            ?? 1
        ...
        cacheHandler.set(info: VideoInfo(...))
```
- Change: if a response provides a more authoritative total, update `info` even if it’s already set. A safe rule:
  - If `info == nil` OR new total is known and (old total is unknown/<=0 OR new > old), then set `info`.

3) Progress stream is already using aggregate on‑disk bytes
- Your updated emitter is good (it now uses `configuration.downloadedByteCount`):
```795:806:PRD/projectStructure/GSPlayer.md
let received = Int64(configuration.downloadedByteCount)
let expectedLen = Int64(configuration.info?.contentLength ?? 0)
let expected = expectedLen > 0 ? expectedLen : nil
```
- With (2) in place, the grid can reach true 100%.

### SwiftUI changes

A) Looping time/seeker
- With the GSPlayer change (emit `.playing` on replay), your wrapper re‑attaches its observer automatically:
```83:90:ViralGen/Utils/VideoPlayer.swift
uiView.stateDidChanged = { [unowned uiView] _ in
    let state: State = uiView.convertState()
    if case .playing = state { context.coordinator.startObserver(uiView: uiView) }
    else { context.coordinator.stopObserver(uiView: uiView) }
```
- Optional hardening: also reset the slider when replay starts by hooking `.onReplay { time = .zero }` in your SwiftUI view that builds `VideoPlayer`.

B) Grid cells showing 98–99% instead of 100%
- In the grid you compute text purely from the ratio:
```248:256:ViralGen/VideoGen/Views/Explore/ExploreContentView.swift
let pct: String = {
    if let exp = progressExpected, exp > 0 {
        let p = Double(progressReceived) / Double(exp)
        return String(format: "%.0f%%", min(max(p, 0), 1) * 100)
    } else {
        return ByteCountFormatter.string(fromByteCount: progressReceived, countStyle: .file)
    }
}()
```
- Keep the ratio for display, but derive “complete” from a boolean and show 100% when complete:
  - Compute `let complete = (progressExpected ?? 0) > 0 && progressReceived >= progressExpected!`
  - If `complete`, render “100%” (or a checkmark), otherwise use the ratio text.
- Why this helps: until GSPlayer updates `contentLength` to the definitive total, a stale/low total can make the ratio wobble. The boolean check ensures exact 100% once totals are authoritative; and with the GSPlayer fix above, the total will converge.

### Summary
- GSPlayer: remove the replay suppression so `.playing` fires on loops; update `info.contentLength` when later responses provide a better total.
- SwiftUI: your observer will re‑attach automatically; in the grid, show “100%” based on a boolean complete check (received ≥ expected), using the ratio only when not complete.