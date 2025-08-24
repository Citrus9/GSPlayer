### PRD: GSPlayer replay stall on loop (fully cached videos)

#### Summary
- **Symptom**: Some fully cached videos play fine on the first pass, but on auto-replay they stall/freeze while the seeker/timer continues moving.
- **Scope**: Not all videos; reproducible only for a subset. Observed in `ExploreDetailView` using `VideoPlayer` (GSPlayer-backed). Cache is on-disk and complete.
- **Likely root cause**: Incorrect or unstable content length reported to AVFoundation during resource loading, caused by treating HTTP 206 `Content-Length` (chunk length) as the total file size when `Content-Range` total is not provided. This can make the loader believe the resource ends early (e.g., ~512 KB). On second play (replay), the loader’s "download to end" path uses that small length, resulting in insufficient bytes supplied and visual stall while AVPlayer time continues.

---

### Observations and hypotheses
1) **First pass OK, replay stalls**
   - First play streams progressively (mix of remote/local actions) and AVFoundation can still advance even if metadata has issues.
   - On replay, `AVAssetResourceLoader` frequently issues a request with `requestsAllDataToEndOfResource == true` starting at offset 0. GSPlayer then uses `downloadToEnd(from:)` that computes length using `info.contentLength`. If that length is wrong/small, only a short prefix is delivered.

2) **Why would `contentLength` be wrong?**
   - In `VideoDownloader.didReceive(response:)` (see `GSPlayer.md`), `candidateContentLength` is selected as:
     - `Content-Range` total if present, else
     - `Content-Length` header, else
     - `expectedContentLength`, else
     - lower bound from `Content-Range` end+1
   - It then marks the candidate as "definitive" if either `Content-Range` total is present OR `Content-Length` exists.
   - For 206 responses, `Content-Length` is the size of the current chunk, not the total file length. Treating it as definitive leads to `info.contentLength = chunkSize` (e.g., 524,288).
   - With `info.contentLength` wrong/small, `VideoRequestLoader.fulfillContentInfomation()` reports this small length to AVFoundation on subsequent requests.

3) **Why only some videos?**
   - Behavior depends on CDN/server headers. Some servers return `Content-Range: bytes start-end/total`. Others return `bytes start-end/*` (unknown total) or omit it, leaving only `Content-Length` for the chunk.

---

### Diagnostics: add bright logs to pinpoint
Add the following logs (with emojis) to confirm the hypothesis and to measure offsets/lengths on replay.

1) `VideoDownloader.didReceive(response:)` — log status, headers, chosen length, and whether we update info
```swift
// GSPlayer.md → in VideoDownloader.didReceive(response:)
#if DEBUG
let status = httpResponse.statusCode
let cr = httpResponse.value(forHeaderKey: "Content-Range") ?? "-"
let cl = httpResponse.value(forHeaderKey: "Content-Length") ?? "-"
let exp = (response.expectedContentLength > 0) ? String(response.expectedContentLength) : "-"
print("🎥 [GS] 🧠 meta — status=\(status) CR=\(cr) CL=\(cl) EXP=\(exp)")
print("🎥 [GS] 🧠 meta — candidate len=\(candidateContentLength) definitive=\(candidateIsDefinitive) prev=\(previousLength) update=\(shouldUpdateInfo)")
#endif
```

2) `VideoRequestLoader.start()` — log request semantics
```swift
// GSPlayer.md → in VideoRequestLoader.start()
#if DEBUG
print("🎥 [GS] 📥 request — allToEnd=\(dataRequest.requestsAllDataToEndOfResource) offset=\(offset) length=\(length) — \(downloader.url.lastPathComponent)")
#endif
```

3) `VideoCacheHandler.actions(for:)` — first N actions to see remote/local segmentation
```swift
// GSPlayer.md → end of actions(for:)
#if DEBUG
let localCount = localRemoteActions.filter { $0.actionType == .local }.count
let remoteCount = localRemoteActions.count - localCount
print("🎥 [GS] 🧮 actions — req=[\(range.location), \(range.length)] local=\(localCount) remote=\(remoteCount)")
#endif
```

4) `VideoRequestLoader.fulfillContentInfomation()` — log what we report to AVFoundation
```swift
// GSPlayer.md → end of fulfillContentInfomation()
#if DEBUG
let repLen = request.contentInformationRequest?.contentLength ?? 0
let repType = request.contentInformationRequest?.contentType ?? "-"
let repRange = request.contentInformationRequest?.isByteRangeAccessSupported ?? false
print("🎥 [GS] 🧾 contentInfo — type=\(repType) len=\(repLen) range=\(repRange)")
#endif
```

5) `VideoDownloader.downloadToEnd(from:)` — confirm the computed length on replay
```swift
// GSPlayer.md → in VideoDownloader.downloadToEnd(from:)
#if DEBUG
print("🎥 [GS] 🔁 toEnd — offset=\(offset) total=\(info?.contentLength ?? -1)")
#endif
```

6) SwiftUI player-side replay & seek logs
```swift
// VideoPlayer.swift → Coordinator/startObserver + state handler, and replay path in VideoPlayerView
// Already has good logs; add around replay/seek completion:
// VideoPlayerView.playerItemDidReachEnd
print("🎥 [VID] 🔁 reachedEnd — autoReplay=\(isAutoReplay)")
// When seeking to 0 for replay
print("🎥 [VID] 🔁 seek→0 (begin)")
uiView.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { ok in
    print("🎥 [VID] 🔁 seek→0 (done ok=\(ok)) — resume")
    self.player?.playImmediately(atRate: speedRate)
}
```

---

### Proposed fixes

#### A. Fix content-length handling (GSPlayer side; recommended)
Reason: Ensure `info.contentLength` is only set from a trustworthy source so `downloadToEnd(from:)` uses a correct value.

1) In `VideoDownloader.didReceive(response:)`, treat 206 `Content-Length` as NON-definitive; only treat as definitive for 200 OK responses.
```swift
// Replace candidateIsDefinitive computation
let isPartial = httpResponse.statusCode == 206
let candidateIsDefinitive = (lengthFromRangeTotal != nil) || (!isPartial && lengthFromHeader != nil)

// Keep the existing candidateContentLength selection order.
// Update shouldUpdateInfo to allow growth even when non-definitive, but never shrink:
let previousLength = info?.contentLength ?? 0
let shouldUpdateInfo = (info == nil) || (candidateContentLength > previousLength)
```

2) After download completes or when we have full cache, prefer the on-disk file size as the authoritative length.
```swift
// In VideoRequestLoader.fulfillContentInfomation()
let filePath = VideoCacheManager.cachedFilePath(for: downloader.url)
let diskLen = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? NSNumber)?.intValue ?? 0
var effectiveLength = info.contentLength
if effectiveLength <= 0 || diskLen > effectiveLength { effectiveLength = diskLen }
request.contentInformationRequest?.contentLength = Int64(max(1, effectiveLength))
request.contentInformationRequest?.isByteRangeAccessSupported = true // we serve ranges from cache
```

3) Guard `downloadToEnd(from:)` against unknown/zero lengths and fallback to disk size
```swift
// In VideoDownloader.downloadToEnd(from:)
public func downloadToEnd(from offset: Int) {
    var total = info?.contentLength ?? 0
    if total <= 0 {
        let path = VideoCacheManager.cachedFilePath(for: url)
        let diskLen = (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        total = diskLen
    }
    let length = total > 0 ? max(0, total - offset) : Int.max // large sweep if total unknown
    #if DEBUG
    print("🎥 [GS] 🔁 toEnd — offset=\(offset) total=\(total) length=\(length)")
    #endif
    download(from: offset, length: length)
}
```

These changes keep `info.contentLength` monotonic-increasing and prevent the loader from advertising a too-small total to AVFoundation.

#### B. SwiftUI/Player side mitigations (optional but helpful)
1) Use zero-tolerance seek and resume in completion to avoid timing races on replay.
```swift
// VideoPlayerView.replay(resetCount:)
player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
    self?.player?.playImmediately(atRate: self?.speedRate ?? 1.0)
}
```

2) Robust fallback: recreate `AVPlayerItem` on replay if we detect stall (time advances but video frames frozen for >0.5s).
```swift
// VideoPlayer.Coordinator — simple stall detector (pseudo)
// If buffer likelyToKeepUp is true, rate > 0, time moving, but layer isn't drawing new frames,
// replace item:
let item = AVPlayerItem(loader: url)
uiView.player?.replaceCurrentItem(with: item)
uiView.player?.playImmediately(atRate: speedRate)
```

#### C. Simplify looping with AVPlayerLooper when fully cached (SwiftUI side)
When the asset is fully cached, bypass the custom loader and use a local file with `AVPlayerLooper` for clean, gapless looping and simpler replay.

Implementation (SwiftUI side – `VideoPlayer.swift`):
```swift
// Detect completion using GSPlayer snapshot
let snap = await VideoDownloadManager.shared.cachedStatus(for: url)
let isComplete = snap.isComplete

if isComplete {
    let path = VideoCacheManager.cachedFilePath(for: url)
    let fileURL = URL(fileURLWithPath: path)
    let item = AVPlayerItem(url: fileURL)
    let queue = AVQueuePlayer(items: [])
    uiView.player = queue
    // Store looper strongly (e.g., in Coordinator)
    context.coordinator.looper = AVPlayerLooper(player: queue, templateItem: item)
    queue.playImmediately(atRate: config.speedRate)
} else {
    // Existing streaming path via AVPlayerItem(loader: url)
}
```

Where to store the looper (Coordinator):
```swift
// VideoPlayer.Coordinator
var looper: AVPlayerLooper? // keep strong reference
```

Notes:
- This is a SwiftUI-side change only. GSPlayer already provides `VideoCacheManager.cachedFilePath(for:)` and `cachedStatus`.
- Keep the existing streaming path for partial/remote cases; only switch to the local file + looper when `isComplete == true`.

---

### Where to change and how
- **GSPlayer (SPM copy in `PRD/projectStructure/GSPlayer.md`):**
  - `VideoDownloader.didReceive(response:)`: adjust `candidateIsDefinitive` and `shouldUpdateInfo` as above and add logs.
  - `VideoRequestLoader.fulfillContentInfomation()`: cap `contentLength` by on-disk size; set `isByteRangeAccessSupported = true`; add logs.
  - `VideoDownloader.downloadToEnd(from:)`: handle unknown total as "to end" by using a large length; add logs if desired.
  - Optional: in `VideoCacheHandler.actions(for:)`, add summary logs of remote/local actions per request.

- **SwiftUI side (`VideoPlayer.swift` / `ExploreContentView.swift`):**
  - Convert replay to zero-tolerance seek with play in completion; add detailed replay logs.
  - Keep existing state logs; consider adding a temporary stall watchdog in `Coordinator` for stubborn cases.

---

### Validation checklist
- With logs enabled, verify for stalling videos:
  - `🧠 meta` shows 206 with `CR` missing total or `*/` and small `CL` values.
  - `🧾 contentInfo` first shows tiny `len` (before fix) and then correct full file length (after fix).
  - On replay, `📥 request` with `allToEnd=true` should trigger a large or full-length delivery, and `🧮 actions` should be entirely `.local` across the requested span.
  - Video loops without freeze; seeker/timer stay in sync with visuals.

---

### Rollout plan
1) Land the GSPlayer-side fixes and logs behind `#if DEBUG` where applicable.
2) Add the SwiftUI replay seek adjustment.
3) Test with:
   - Known-stalling videos.
   - Short and long assets.
   - Assets where server returns `Content-Range` with and without total.
4) Remove/trim verbose logs after verification.

---

### Appendix: quick grep targets
- `GSPlayer.md`: `VideoDownloader.didReceive`, `VideoRequestLoader.fulfillContentInfomation`, `VideoDownloader.downloadToEnd`, `VideoCacheHandler.actions`.
- `VideoPlayer.swift`: `VideoPlayerView.playerItemDidReachEnd`, `Coordinator`.


