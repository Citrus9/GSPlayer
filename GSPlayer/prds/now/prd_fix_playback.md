### What you’re observing
- The player keeps advancing the playhead instead of stalling when it runs out of buffered bytes, and your “cached %” HUD often shows much less than what playback seems to be using.

### Root cause 1: You’re force-resuming playback and disabling AVPlayer’s stall handling
- You disable AVPlayer’s normal rebuffering behavior:
```2373:2378:PRD/projectStructure/GSPlayer.md
let player = AVPlayer()
player.automaticallyWaitsToMinimizeStalling = false
```
- Then every time the player transitions to `.paused`, you immediately force it to resume, even if it paused because it ran out of data:
```2525:2534:PRD/projectStructure/GSPlayer.md
case .paused:
    guard !self.isReplay else { break }
    self.state = .paused(playProgress: self.playProgress, bufferProgress: self.bufferProgress)
    if self.pausedReason == .waitingKeepUp { player.playImmediately(atRate: speedRate) }
case .waitingToPlayAtSpecifiedRate:
    break
```
- Result: the player never gets a chance to stay stalled; it keeps being nudged to “play now,” so time continues to advance in bursts (and your slider follows), instead of pausing until more bytes arrive.

How to fix:
- Remove the auto-resume in the `.paused` branch and resume only when `isPlaybackLikelyToKeepUp` flips true (which you already observe here):
```2572:2578:PRD/projectStructure/GSPlayer.md
if item.isPlaybackLikelyToKeepUp {
    if self.player?.rate == 0, self.pausedReason == .waitingKeepUp {
        self.player?.playImmediately(atRate: speedRate)
    }
}
```
- Or simply set `player.automaticallyWaitsToMinimizeStalling = true` and let AVPlayer manage stalling/rebuffering.

Also consider treating `.waitingToPlayAtSpecifiedRate` as a “loading/paused” state in your state machine (instead of “do nothing”), so your UI and observer behavior match reality.

### Root cause 2: Your HUD’s “cached %” is under-reporting progress
- The progress stream you display uses the handler’s current action offset, not the total downloaded bytes. It resets per action and does not reflect the aggregate cache on disk:
```795:805:PRD/projectStructure/GSPlayer.md
let received = Int64(startOffset)
let expected = Int64(configuration.info?.contentLength ?? 0)
let progress = DownloadProgress(url: urlCopy, receivedBytes: received, expectedBytes: expected > 0 ? expected : nil, priority: pr)
```
- That’s why you can see “~30%” while playback continues—your overlay is just showing the current subrange progression, not total cached data.

How to fix:
- Publish aggregate bytes (e.g., `configuration.downloadedByteCount`) in the progress stream, or keep using `cachedStatus(for:)` (which is correct and aggregated) to drive the HUD:
```1190:1199:PRD/projectStructure/GSPlayer.md
let downloaded = Int64(cfg?.downloadedByteCount ?? 0)
```

### Minor contributors
- Starting playback as soon as `isEnoughToPlay` (768 KB) may start too aggressively; consider a larger threshold or set `preferredForwardBufferDuration`.
- Your current state mapping ignores `.waitingToPlayAtSpecifiedRate`, which keeps your wrapper in a “playing” mindset longer than it should.

### What to change (no implementation, just the edits to make)
- Remove the forced resume in the `.paused` branch; resume only on `isPlaybackLikelyToKeepUp`, or re-enable `automaticallyWaitsToMinimizeStalling`.
- Emit aggregate cached bytes in your progress stream, or base the HUD entirely on `cachedStatus(for:)`.
- Optionally, treat `.waitingToPlayAtSpecifiedRate` as a paused/loading state for UI and to suspend the time observer.

- Video keeps progressing because stall handling is disabled and you force resume on pause; your HUD also under-reports cached bytes due to using per-action offsets. Switching to natural stall handling and reporting aggregate cached bytes will restore normal streaming behavior and accurate UI.