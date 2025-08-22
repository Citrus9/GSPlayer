## PRD: GSPlayer video prefetch reliability and "Cannot Open" (-11829) fix

### Context
- App starts in `ViralGen/ViralGenApp.swift` and calls `ExploreService.start()`.
- Explore data drives `ExploreContentView` grid (images + videos).
- Video playback and caching use custom SPM-based GSPlayer (see `PRD/projectStructure/GSPlayer.md`) bridged by `ViralGen/Utils/VideoPlayer.swift`.

### Symptoms
- On app launch, videos in Explore grid do not appear to prefetch. Prefetching seems to begin only after opening the detail view (playback).
- After opening a video (detail), closing, and reopening it, playback intermittently fails with AVFoundation error: `-11829 Cannot Open` and the video view remains black thereafter.

### Root cause analysis
1) Incorrect or incomplete content info for AVAssetResourceLoader
   - In our GSPlayer fork, content metadata for `AVAssetResourceLoadingRequest.contentInformationRequest` is filled from the HTTP response via `VideoDownloader.handler(_:didReceive:)` and later applied by `VideoRequestLoader.fulfillContentInfomation()`.
   - Two issues:
     - We store the server MIME type (e.g., `video/mp4`) and pass it directly as `contentType`. AVFoundation expects a UTType/UTI identifier (e.g., `public.mpeg-4`), not a MIME string. Using MIME can lead to intermittent `Cannot Open` failures, especially after reusing assets or when requests are interrupted.
     - We parse only `Content-Range` to determine `contentLength`. Servers that respond with `200 OK` and `Content-Length` (or respond with `octet-stream`) yield `contentLength = 0`. We then truncate the cache file to 0 bytes, corrupting the local cache and causing subsequent opens to fail with `-11829`.

2) Overly strict MIME gate in downloader
   - In `VideoDownloaderHandler.urlSession(_:didReceive:completionHandler:)`, we cancel unless `response.mimeType.contains("video/")`. Legit servers sometimes return `application/octet-stream` (or other generic/binary types) for MP4. Cancelling such responses prevents prefetch or playback.

3) Prefetch initiation vs. priority-only scheduling
   - The grid boosts priorities via `VideoDownloadManager.setPriority` when switching lists and cells appear, but `setPriority` alone does not start a download if none exists. Only `prefetch(urls:byteCount:priority:)` or a player request will create tasks.
   - `ExploreService.prefetchMedia` runs after start, but two architectural factors reduce observable video prefetch on launch:
     - Stress-test mode appends many image-only items, and the current weighted diagonal batching often front-loads images. Video batches may come later, delaying visible network activity for videos.
     - There is no explicit "video head prewarm" for the top items of each list to ensure prompt, predictable video prefetch.

4) Loader lifecycle can leave stale loaders
   - When a detail view is dismissed mid-load, AVFoundation sends `didCancel` to the resource loader, and we mark the request as cancelled. However, the `VideoLoader` instance can remain in `VideoLoadManager.loaderMap` without being invalidated. A stale loader combined with 0-byte or incorrect content info can exacerbate reopen failures.

### Fixes

#### Fix 1: Robust content metadata and UTType mapping
Apply both changes below.

- Parse `Content-Length` when `Content-Range` is absent (fall back to `Content-Length`).
- Store MIME in `VideoInfo`, but convert MIME → UTType identifier before assigning `contentInformationRequest.contentType`.

Example changes:

```swift
// In VideoDownloader.handler(_:didReceive:)
// Fallback to Content-Length if Content-Range is missing
let contentLengthFromRange = httpResponse
    .value(forHeaderKey: "Content-Range")?
    .split(separator: "/")
    .last
    .flatMap { Int($0) }

let contentLengthFromLength = httpResponse
    .value(forHeaderKey: "Content-Length")
    .flatMap { Int($0) }

let contentLength = contentLengthFromRange ?? contentLengthFromLength ?? 0

let contentType = httpResponse.value(forHeaderKey: "Content-Type") ?? "video/mp4"
let isByteRangeAccessSupported = httpResponse
    .value(forHeaderKey: "Accept-Ranges")?
    .contains("bytes") ?? false

cacheHandler.set(info: VideoInfo(
    contentLength: contentLength,
    contentType: contentType,
    isByteRangeAccessSupported: isByteRangeAccessSupported
))
```

```swift
// In VideoRequestLoader.fulfillContentInfomation()
import UniformTypeIdentifiers

guard let info = downloader.info, let cir = request.contentInformationRequest else { return }

let mime = info.contentType
let utType = UTType(mimeType: mime)
    ?? UTType(filenameExtension: downloader.url.pathExtension)
    ?? .mpeg4Movie

cir.contentType = utType.identifier            // e.g., "public.mpeg-4"
cir.contentLength = Int64(info.contentLength)  // must be > 0
cir.isByteRangeAccessSupported = info.isByteRangeAccessSupported
```

Why: AVFoundation requires a UTType identifier, not a MIME string. Ensuring `contentLength > 0` prevents 0-byte truncation issues and improves reliability across resume/reopen cases.

#### Fix 2: Relax MIME gate for valid video responses

```swift
// In VideoDownloaderHandler.urlSession(_:dataTask:didReceive:completionHandler:)
#if !os(macOS)
let mime = response.mimeType ?? ""
let isLikelyVideo = mime.contains("video/") || mime == "application/octet-stream" || mime == "binary/octet-stream"
guard isLikelyVideo else { completionHandler(.cancel); return }
#endif
completionHandler(.allow)
```

Why: Some CDNs or signed URLs return generic content types; rejecting them blocks prefetch/playback.

#### Fix 3: Proactive video head prefetch on app start

Add a targeted head-prefetch for the top N video items per list so we always warm the first screen.

```swift
// In ExploreService
@MainActor
func startHeadPrefetchForTopVideos(maxPerList: Int = 6, bytes: Int = 1_048_576, priority: Float = 0.4) async {
    let orderedListIds = lists.map { $0.id }
    var urls: [URL] = []
    for lid in orderedListIds {
        guard let items = itemsByListId[lid] else { continue }
        let topVideos = items.filter { $0.type == .video }
                              .prefix(maxPerList)
                              .compactMap { $0.videoUrl }
                              .compactMap(URL.init(string:))
        urls.append(contentsOf: topVideos)
    }
    guard !urls.isEmpty else { return }
    await VideoDownloadManager.shared.prefetch(urls: Array(Set(urls)), byteCount: bytes, priority: priority)
}
```

Call it right after `start()` completes applying cache/fresh data (or from app init after `exploreService.start()`):

```swift
// In ViralGenApp.initializeApp()
exploreService.start()
Task { await exploreService.startHeadPrefetchForTopVideos() }
```

Why: Ensures visible videos begin warming immediately, regardless of batching weights or stress-test image density.

#### Fix 4: Make grid visibility affect downloads (pin/unpin)

Use pins to keep a small set of visible items hot rather than only nudging priority. Pins survive priority sweeps and avoid starvation.

```swift
// In ExploreGridCell.handleAppear()
if item.type == .video, let s = item.videoUrl, let url = URL(string: s) {
    let pr: Float = isPageActive ? 0.9 : 0.6
    Task {
        await VideoDownloadManager.shared.pin(url: url, scope: "gridVisible", priority: pr)
    }
}

// In ExploreGridCell.handleDisappear()
if item.type == .video, let s = item.videoUrl, let url = URL(string: s) {
    Task { await VideoDownloadManager.shared.unpin(url: url, scope: "gridVisible") }
}
```

Why: Priority-only updates don’t start downloads; pinning guarantees active scheduling for currently visible items.

#### Fix 5: Explicitly invalidate loaders when a detail view closes

Provide a safe invalidation API to remove stale loaders after a view is dismissed.

```swift
// In VideoLoadManager
public func invalidate(url: URL) {
    if let loader = loaderMap[url] {
        loader.cancel()
        loaderMap.removeValue(forKey: url)
    }
}
```

```swift
// In ExploreDetailView.onDisappear (video case)
if let url = URL(string: item.videoUrl ?? "") {
    VideoLoadManager.shared.invalidate(url: url)
}
```

Why: Ensures no half-finished loaders persist across quick dismiss/reopen cycles.

### Architectural improvements
- "Download intent" vs. "priority": make intent explicit.
  - Add an API like `ensurePrefetch(url:byteCount:priority:)` that starts a task if none exists. Use this when switching lists or when a cell becomes visible.
- Two-phase prefetch for Explore:
  - Phase A: immediate head-prefetch for top-of-grid videos across current and adjacent lists (fast first-paint benefit).
  - Phase B: background weighted-diagonal sweep for depth coverage (current batching).
- MIME/UTType normalization at a single choke point.
  - Keep all MIME→UTType logic in one helper for reuse by both downloader and request loader.
- Observability and backoff:
  - Log `contentLength`, `contentType` (MIME and UTType), and effective priority per URL.
  - Back off retries on repeated `Cannot Open` (-11829) for a short period and invalidate loader to prevent reuse of bad state.

### Rollout plan
1) Implement Fix 1 and Fix 2 in GSPlayer (SPM). Unit-test UTType mapping and content-length fallback.
2) Ship Fix 3 via `ExploreService.startHeadPrefetchForTopVideos()` and invoke from `ViralGenApp.initializeApp()`.
3) Add pin/unpin in `ExploreGridCell` (Fix 4). Verify network activity starts without entering detail.
4) Add loader invalidation (Fix 5). Verify reopen after immediate dismiss no longer triggers `-11829`.
5) Monitor logs and cache sizes; adjust `preloadByteCount` and concurrency after field data.

### Risks
- More liberal MIME acceptance could fetch non-video responses if URLs are misconfigured. Mitigate via domain allowlist and size sanity checks.
- Head-prefetch adds network use on start; keep `maxPerList` small (3–6) and tune priorities.

### Success criteria
- Videos begin prefetching soon after app launch (confirmed by logs and cache growth) without entering detail.
- No reproducible `-11829 Cannot Open` after dismiss/reopen.
- Smooth playback with reduced black frames and faster start times.


