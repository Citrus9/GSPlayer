## GSPlayer prefetching and “Cannot Open” error analysis

### Context
- Explore grid UI: `ViralGen/VideoGen/Views/Explore/ExploreContentView.swift`
- Startup wiring: `ViralGen/ViralGenApp.swift`
- Data + prefetch orchestration: `ViralGen/Services/Explore/ExploreService.swift`
- Video runtime (custom SPM): GSPlayer (see types mirrored in `PRD/projectStructure/GSPlayer.md`)
- SwiftUI bridge to GSPlayer: `ViralGen/Utils/VideoPlayer.swift`

### Symptoms
- Videos in Explore grid are not prefetched on cold start. Prefetch seems to begin only after entering a video detail view.
- After opening a video (still loading), closing it, and reopening, playback fails with AVFoundation error: `-11829 Cannot Open`, and the player shows black.

---

## Root causes

### 1) Prefetch downloaders are immediately deallocated (no strong owner)
Where: GSPlayer → `VideoDownloadManager.prefetch(...)`

- The prefetch path creates a local `VideoDownloader` and starts it, but does not retain it. The session’s delegate router (`VideoDownloaderSessionDelegateHandler`) stores only a weak reference to per-task delegates. As soon as the local `VideoDownloader` falls out of scope, its internal `VideoDownloaderHandler` (the delegate) is deallocated. From that point, URLSession callbacks have no live delegate to receive bytes; nothing gets cached.

Why it explains symptoms:
- Grid prefetch runs through `ExploreService.prefetchVideos(...)` → `VideoDownloadManager.prefetch(...)`. Because the downloader isn’t retained, prefetch does nothing visible. Entering the detail view uses `VideoLoader` which keeps a strong `downloader` property, so playback “seems” to kick off downloads.

Fix: Retain prefetch downloaders in `VideoDownloadManager` until the last task for that URL completes.

Example change:
```swift
// In VideoDownloadManager (actor)
private var prefetchers: [URL: VideoDownloader] = [:]

public func prefetch(urls: [URL], byteCount: Int, priority: Float) {
    for url in urls {
        Task { [priority] in
            if await self.isDownloading(url: url) { return }
            if let cfg = try? VideoCacheManager.cachedConfiguration(for: url),
               cfg.downloadedByteCount >= byteCount { return }

            await self.setPriority(for: url, priority: priority)
            do {
                let cacheHandler = try VideoCacheHandler(url: url)
                if cacheHandler.configuration.downloadedByteCount < byteCount {
                    let downloader = VideoDownloader(url: url, cacheHandler: cacheHandler)
                    await self.retainPrefetcher(downloader, for: url)
                    downloader.download(from: 0, length: byteCount)
                }
            } catch { /* ignore */ }
        }
    }
}

private func retainPrefetcher(_ downloader: VideoDownloader, for url: URL) {
    prefetchers[url] = downloader
}

public func untrack(taskIdentifier: Int) {
    if let url = taskIdToURL.removeValue(forKey: taskIdentifier) {
        urlToTaskIds[url]?.remove(taskIdentifier)
        if urlToTaskIds[url]?.isEmpty == true {
            urlToTaskIds.removeValue(forKey: url)
            // Release once the final task for this URL completes
            prefetchers.removeValue(forKey: url)
        }
    }
}
```

Result:
- Prefetch jobs survive long enough to receive bytes and persist to cache. Grid prefetch now works at cold start (no need to open detail view first).

---

### 2) Over‑strict MIME check cancels valid responses
Where: GSPlayer → `VideoDownloaderSessionDelegateHandler.urlSession(_:dataTask:didReceive:completionHandler:)`

- Current code cancels any response whose `mimeType` does not contain `"video/"` (iOS only). Many CDNs legitimately return `application/octet-stream` for ranged video bytes. Those responses get canceled, causing aborted downloads and subsequent AVFoundation failures.

Fix: Remove the MIME gate or relax it to allow common binary types. Prefer allowing any 2xx/206 response and let downstream parsing guard.

Example change:
```swift
func urlSession(_ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if let http = response as? HTTPURLResponse,
       (200..<300).contains(http.statusCode) || http.statusCode == 206 {
        delegate?.handler(self, didReceive: response)
        completionHandler(.allow)
    } else {
        completionHandler(.cancel)
    }
}
```

Result:
- Prefetch and playback no longer fail when servers send `application/octet-stream` for byte ranges. Eliminates a major source of `-11829` after reopening.

---

### 3) Disk space guard blocks all writes (uses a frequently-nil key)
Where: GSPlayer → `VideoCacheHandler.cache(data:for:)`

- The write path checks `.volumeAvailableCapacityKey` on the caches directory URL. On modern iOS this key is often nil (Apple recommends the `...ForImportantUsage` variants). When nil, the guard fails and returns `false` without writing any bytes to cache.

Fix: Use `volumeAvailableCapacityForImportantUsageKey` with a safe fallback, or remove the check for these small writes.

Example change:
```swift
func cache(data: Data, for range: NSRange) -> Bool {
    objc_sync_enter(writeFileHandle); defer { objc_sync_exit(writeFileHandle) }

    do {
        let cachesURL = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let values = try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let cap = values?.volumeAvailableCapacityForImportantUsage, cap < Int64(data.count) {
            return false
        }
    } catch { /* ignore capacity check on error */ }

    do { try writeFileHandle.seekToEnd() } catch { return false }
    writeFileHandle.seek(toFileOffset: UInt64(range.location))
    writeFileHandle.write(data)
    configuration.add(fragment: range)
    return true
}
```

Result:
- Prefetch and streaming writes actually hit disk; subsequent opens can reuse cached bytes instead of re-requesting, reducing AVAsset load errors.

---

### 4) Concurrency tuning has no effect
Where: GSPlayer → `VideoDownloadManager.setConcurrency(...)`

- `setConcurrency` only updates stored integers; it does not reconfigure the `URLSession`. The session is created once with a default config (`httpMaximumConnectionsPerHost = 6`).

Fix (optional): Allow recreating the session with updated limits (do this when no active tasks, or accept that limits apply to the next launch).

Example approach:
```swift
private func recreateSessionIfIdle() async {
    let tasks = await session.getAllTasksAsync()
    guard tasks.isEmpty else { return }
    let cfg = URLSessionConfiguration.default
    cfg.waitsForConnectivity = true
    cfg.httpMaximumConnectionsPerHost = perHost
    cfg.timeoutIntervalForRequest = 60
    cfg.timeoutIntervalForResource = 120
    session = URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: delegateQueue)
}

public func setConcurrency(maxActive: Int, perHost: Int) {
    self.maxActive = maxActive
    self.perHost = perHost
    Task { await recreateSessionIfIdle() }
}
```

Result:
- More predictable network behavior when tuning concurrency. Not required to fix the current bug, but recommended.

---

## Smaller observations and recommendations

- Explore prefetch runs correctly from `ViralGenApp.initializeApp()` → `exploreService.start()`. The lack of visible prefetch was primarily retention + MIME gate + disk-write issues above.
- `ExploreService.isStressTestEnabled` adds 100 dummy images per list. Keep this off in production to reduce bandwidth spikes and improve perceived prefetch progress signal.
- In `ExploreContentView`, grid cells correctly set `VideoDownloadManager` priorities on appear/disappear. That prioritization will be more effective once the manager actually retains downloads.
- Consider logging HTTP status codes and `Content-Type` for first responses in `VideoDownloaderHandler` to aid future diagnosis of CDN quirks (especially 206 vs 200 and 416 errors).

---

## Implementation plan (ordered)

1) Retain prefetchers in `VideoDownloadManager` and release them when the last task for a URL completes.
2) Remove or relax the MIME type gate in `VideoDownloaderSessionDelegateHandler.didReceive response`.
3) Fix the disk space guard in `VideoCacheHandler.cache(data:for:)` to use `volumeAvailableCapacityForImportantUsage` or to permit writes when unknown.
4) (Optional) Make `setConcurrency` actually reconfigure the session when idle.
5) Add debug logging for first response: status code, `Content-Type`, and range headers to quickly spot incorrect server responses.

Testing checklist:
- Clear caches → cold start → watch console for prefetch logs: “📦 Video prefetch batch …” and “🎥 [GS] 📦 Prefetch …”. Verify `.mp4` head files are created under the app’s Caches/GSPlayer directory.
- Open detail while a prefetch is in flight; video should start instantly or faster, with no `-11829` errors.
- Close detail mid-load and reopen; playback should succeed (no black frames); confirm `VideoCacheConfiguration.downloadedByteCount` steadily grows across attempts.

---

## Code snippets to drop in (summary)

### Retain prefetchers in manager
```swift
// VideoDownloadManager (actor)
private var prefetchers: [URL: VideoDownloader] = [:]

private func retainPrefetcher(_ downloader: VideoDownloader, for url: URL) {
    prefetchers[url] = downloader
}

public func untrack(taskIdentifier: Int) {
    if let url = taskIdToURL.removeValue(forKey: taskIdentifier) {
        urlToTaskIds[url]?.remove(taskIdentifier)
        if urlToTaskIds[url]?.isEmpty == true {
            urlToTaskIds.removeValue(forKey: url)
            prefetchers.removeValue(forKey: url)
        }
    }
}
```

### Relax MIME filter
```swift
// VideoDownloaderSessionDelegateHandler
func urlSession(_ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    delegate?.handler(self, didReceive: response)
    completionHandler(.allow)
}
```

### Disk space check fix
```swift
// VideoCacheHandler.cache(data:for:)
let cachesURL = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
let values = try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
if let cap = values?.volumeAvailableCapacityForImportantUsage, cap < Int64(data.count) { return false }
```

---

## Architectural improvements

- Ownership model: Treat in-flight network jobs as first-class entities owned by a manager with explicit lifecycle. Avoid weak-only delegate chains without a strong owner.
- Robustness to CDN variance: Avoid assuming video MIME types for ranged byte responses. Gate on HTTP status (200/206) and recover gracefully from 416 by recomputing ranges if needed.
- Persistence correctness: Ensure cache writes are not blocked by platform-specific availability APIs; allow “best-effort” writes for small prefetches.
- Telemetry: Add basic counters (bytes written, fragments merged, first-error classification). This dramatically reduces time-to-root-cause for future incidents.

With these targeted fixes, Explore prefetch will work at app launch, and reopening videos will no longer trigger `-11829 Cannot Open` or black playback.


