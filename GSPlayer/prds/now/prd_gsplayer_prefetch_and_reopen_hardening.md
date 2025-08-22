## PRD: GSPlayer – Reliable prefetch and reopen playback (−11829) hardening

### Scope
- Applies only to the GSPlayer SPM package (downloader, cache, loader, session, and logging).
- No SwiftUI/app-side changes here. A separate PRD will cover UI integration and Explore orchestration.

### Goals
- Ensure video prefetch actually downloads and caches bytes at app start.
- Eliminate reopen failures (AVFoundation error −11829 “Cannot Open”) and black playback.
- Provide bright, structured logs for quick diagnosis in the field.

### Non-goals
- Changing high-level Explore prefetch strategy (that lives in the app).
- Changing playback UI or SwiftUI bridging behavior beyond required loader/cache fixes.

---

## Problems and root causes (GSPlayer side)

- Prefetch downloaders are not retained → tasks get canceled when delegates deallocate.
- Response MIME gate is too strict → valid `206`/`200` responses (e.g., `application/octet-stream`) are canceled.
- AVFoundation content metadata is incorrect:
  - `contentType` passed as MIME, but AVFoundation expects a UTType identifier.
  - `contentLength` can be 0 when only `Content-Length` exists (no `Content-Range`).
- Disk capacity guard uses a frequently-nil key → small writes are blocked (no cache progress).
- Session concurrency setter does not reconfigure the session (optional improvement).
- Lacking focused logs for first response, capacity guard, metadata mapping, and lifecycle of prefetchers/tasks.

---

## High-level design

1) Ownership: treat prefetch downloaders as first-class owned by `VideoDownloadManager`; retain until last task per-URL completes.
2) Transport acceptance: allow `200/206` responses regardless of MIME; only reject on non-success HTTP or clear non-video cases server-side.
3) Metadata correctness: compute `contentLength` from `Content-Range` OR fallback to `Content-Length`; map MIME → UTType and pass UTType identifier to AVFoundation.
4) Persistence robustness: use `volumeAvailableCapacityForImportantUsageKey` (with fallback) or skip capacity checks for small writes.
5) Instrumentation: add bright, structured logs at critical points.
6) Optional: reconfigure `URLSession` concurrency when idle to honor updated limits.

---

## Detailed changes (with sample code)

Note: Class and method names match the existing GSPlayer structure.

### 1) Retain prefetch downloaders (lifecycle)

File: `VideoDownloadManager.swift`

```swift
public actor VideoDownloadManager {
    // ... existing code ...

    private var prefetchers: [URL: VideoDownloader] = [:]

    private func retainPrefetcher(_ downloader: VideoDownloader, for url: URL) {
        prefetchers[url] = downloader
        print("🎥 [GS] 📌 retain prefetcher — \(url.lastPathComponent)")
    }

    private func releasePrefetcherIfIdle(for url: URL) {
        if urlToTaskIds[url]?.isEmpty != false {
            prefetchers.removeValue(forKey: url)
            print("🎥 [GS] 🧹 release prefetcher — \(url.lastPathComponent)")
        }
    }

    public func untrack(taskIdentifier: Int) {
        if let url = taskIdToURL.removeValue(forKey: taskIdentifier) {
            urlToTaskIds[url]?.remove(taskIdentifier)
            if urlToTaskIds[url]?.isEmpty == true {
                urlToTaskIds.removeValue(forKey: url)
            }
            releasePrefetcherIfIdle(for: url)
        }
    }

    public func prefetch(urls: [URL], byteCount: Int, priority: Float) {
        for url in urls {
            Task { [priority, byteCount] in
                if await isDownloading(url: url) { return }
                if let cfg = try? VideoCacheManager.cachedConfiguration(for: url),
                   cfg.downloadedByteCount >= byteCount { return }
                await setPriority(for: url, priority: priority)
                do {
                    let cacheHandler = try VideoCacheHandler(url: url)
                    if cacheHandler.configuration.downloadedByteCount < byteCount {
                        let downloader = VideoDownloader(url: url, cacheHandler: cacheHandler)
                        await retainPrefetcher(downloader, for: url)
                        print("🎥 [GS] 📦 prefetch start — \(byteCount)B — prio=\(priority) — \(url.lastPathComponent)")
                        downloader.download(from: 0, length: byteCount)
                    }
                } catch {
                    print("🎥 [GS] ❌ prefetch init failed — \(url.lastPathComponent) — \(error.localizedDescription)")
                }
            }
        }
    }
}
```

### 2) Relax MIME gate (accept valid video bytes)

File: `VideoDownloaderSessionDelegateHandler.swift`

```swift
func urlSession(_ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if let http = response as? HTTPURLResponse {
        let code = http.statusCode
        if (200..<300).contains(code) || code == 206 {
            print("🎥 [GS] 🛰️ response ok — status=\(code) mime=\(response.mimeType ?? "")")
            delegate?.handler(self, didReceive: response)
            completionHandler(.allow)
            return
        }
        print("🎥 [GS] 🚫 response rejected — status=\(code)")
        completionHandler(.cancel)
        return
    }
    // Non-HTTP: allow and let downstream validate
    delegate?.handler(self, didReceive: response)
    completionHandler(.allow)
}
```

### 3) Content metadata correctness (length + UTType mapping)

Files: `VideoDownloader.swift`, `VideoRequestLoader.swift`

```swift
// VideoDownloader.handler(_:didReceive:)
if info == nil, let http = response as? HTTPURLResponse {
    let lengthFromRange = http.value(forHeaderKey: "Content-Range")?
        .split(separator: "/").last
        .flatMap { Int($0) }
    let lengthFromHeader = http.value(forHeaderKey: "Content-Length").flatMap { Int($0) }
    let contentLength = lengthFromRange ?? lengthFromHeader ?? 0

    let contentType = http.value(forHeaderKey: "Content-Type") ?? "video/mp4"
    let isByteRange = http.value(forHeaderKey: "Accept-Ranges")?.contains("bytes") ?? false

    cacheHandler.set(info: VideoInfo(
        contentLength: contentLength,
        contentType: contentType,
        isByteRangeAccessSupported: isByteRange
    ))
    print("🎥 [GS] 🧠 meta — len=\(contentLength) type=\(contentType) range=\(isByteRange)")
}
```

```swift
// VideoRequestLoader.fulfillContentInfomation()
import UniformTypeIdentifiers

guard let info = downloader.info, let cir = request.contentInformationRequest else { return }

let mime = info.contentType
let utType = UTType(mimeType: mime)
    ?? UTType(filenameExtension: downloader.url.pathExtension)
    ?? .mpeg4Movie

cir.contentType = utType.identifier
cir.contentLength = Int64(max(info.contentLength, 0))
cir.isByteRangeAccessSupported = info.isByteRangeAccessSupported

print("🎥 [GS] 🧠 contentInfo — utType=\(utType.identifier) len=\(cir.contentLength) range=\(cir.isByteRangeAccessSupported)")
```

### 4) Disk capacity guard fix

File: `VideoCacheHandler.swift`

```swift
func cache(data: Data, for range: NSRange) -> Bool {
    objc_sync_enter(writeFileHandle); defer { objc_sync_exit(writeFileHandle) }

    do {
        let cachesURL = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        let values = try? cachesURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let cap = values?.volumeAvailableCapacityForImportantUsage, cap < Int64(data.count) {
            print("🎥 [GS] 🧮 low disk — cap=\(cap) need=\(data.count)")
            return false
        }
    } catch {
        // Ignore capacity check on error; proceed with best-effort cache write
    }

    do { try writeFileHandle.seekToEnd() } catch { return false }
    writeFileHandle.seek(toFileOffset: UInt64(range.location))
    writeFileHandle.write(data)
    configuration.add(fragment: range)
    return true
}
```

### 5) Optional: session concurrency reconfigure when idle

File: `VideoDownloadManager.swift`

```swift
public actor VideoDownloadManager {
    // ... existing code ...
    private var maxActive = 3
    private var perHost = 2

    private func recreateSessionIfIdle() async {
        let tasks = await session.getAllTasksAsync()
        guard tasks.isEmpty else { return }
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = perHost
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: delegateQueue)
        print("🎥 [GS] ⚙️ session reconfigured — perHost=\(perHost)")
    }

    public func setConcurrency(maxActive: Int, perHost: Int) {
        self.maxActive = maxActive
        self.perHost = perHost
        Task { await recreateSessionIfIdle() }
    }
}
```

### 6) New public API: invalidate loaders (stale state cleanup)

File: `VideoLoadManager.swift`

```swift
public func invalidate(url: URL) {
    if let loader = loaderMap[url] {
        loader.cancel()
        loaderMap.removeValue(forKey: url)
        print("🎥 [GS] 🧯 invalidate loader — \(url.lastPathComponent)")
    }
}
```

### 7) Logging guidelines (bright, structured)

- Prefix all logs with `🎥 [GS]` and a secondary emoji for category:
  - **📦 prefetch**: start/finish/skip; bytes; priority.
  - **🛰️ response**: first response per task; status, MIME.
  - **🧠 meta**: content length, MIME, UTType mapping.
  - **💾 cache**: writes, fragments, saved.
  - **🧮 capacity**: low disk/blocked writes.
  - **⚙️ session**: session (re)config.
  - **📌/🧹 retain/release**: prefetcher lifecycle.
  - **❌ errors**: include `error.code` and `localizedDescription`.

Example messages are shown in the code above.

---

## Configuration knobs (non-breaking)

- `VideoPreloadManager.preloadByteCount` (default 1 MB) — leave as-is here.
- `VideoDownloadManager.setConcurrency(maxActive:perHost:)` — now effective when idle.
- Optional compile-time toggle to silence logs for release builds.

---

## Testing & validation checklist

1) Cold start prefetch
- Clear GSPlayer cache; launch app.
- Expect logs:
  - `📦 prefetch start` for top URLs triggered by app.
  - `🛰️ response ok` and `🧠 meta` for each URL.
  - Increasing fragments/bytes on disk.

2) Detail open → dismiss → reopen
- While first open is still loading, dismiss and reopen the same video.
- Expect: no `−11829` errors; playback begins using cached head.
- Logs show correct `UTType` and non-zero `contentLength`.

3) CDN variants
- Test endpoints with `application/octet-stream` and proper `video/mp4`.
- Ensure no cancellations due to MIME.

4) Low disk behavior
- Simulate low disk; verify `🧮 low disk` appears and writes skip gracefully.

5) Concurrency (optional)
- Set custom `perHost`, ensure session reconfigures when idle; verify with multiple parallel downloads.

---

## Rollout plan

1) Implement changes behind a minor version bump of GSPlayer.
2) Unit tests for header parsing (Content-Range/Content-Length) and UTType mapping.
3) Integrate into the app; enable verbose logs in a test build.
4) Verify the checklist above; adjust byte counts/priorities as needed.
5) Disable verbose logs for production or gate them behind a build flag.

---

## Risks and mitigations

- Accepting broader MIME could admit non-video responses if URLs are misconfigured.
  - Mitigate via domain allowlist upstream and status-code checks here.
- Retaining prefetchers increases memory briefly under heavy prefetch.
  - Mitigate by releasing on last-task completion (already implemented).
- UTType mapping fallbacks could mismatch exotic formats.
  - Fallback to `.mpeg4Movie`; log mapping.

---

## Acceptance criteria

- Prefetch writes bytes on cold start without entering detail.
- No reproducible `−11829 Cannot Open` after dismiss/reopen.
- Logs clearly show response acceptance, metadata mapping, and cache progress.


