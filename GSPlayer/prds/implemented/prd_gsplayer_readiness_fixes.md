## PRD — GSPlayer Readiness Fixes (Pre-Integration)

### Objective
Bring the current `GSPlayer.md` implementation up to the iOS 17+ Swift Concurrency design specified in the improvements PRD so it’s safe, priority-aware, and ready for integration in ViralGen.

---

## Summary of Missing Pieces and Why They Matter

1) URLSession delegate on main thread (performance risk)
- Issue: Some code paths (e.g., `VideoDownloaderHandler`) use `delegateQueue: .main`.
- Why it matters: Delegate callbacks perform buffering, range decisions, and disk I/O; running them on the main thread risks UI jank.
- Fix: Move to a dedicated utility `OperationQueue` owned by `VideoDownloadManager`.

2) Centralized session ownership in VideoDownloadManager (orchestration)
- Issue: Downloaders create their own URLSession instances.
- Why it matters: The scheduler cannot globally control concurrency/priority if sessions are fragmented.
- Fix: `VideoDownloadManager` owns a single shared `URLSession` with appropriate configuration and provides it to download handlers.

3) AsyncStream progress pipeline (clarity & Swift Concurrency)
- Issue: Progress is mainly NotificationCenter-driven; `AsyncStream` isn’t wired as the primary stream.
- Why it matters: App integration (`ExploreContentView`) will consume `AsyncStream` to drive UI.
- Fix: Implement per-URL `AsyncStream<DownloadProgress>` in `VideoDownloadManager` and publish throttled updates from downloader events.

4) CacheIO actor adoption across writes (thread safety)
- Issue: `VideoCacheHandler` is called directly inside delegates; using `objc_sync` on file handles but not isolating higher-level state.
- Why it matters: We need one serialization point for disk and sidecar saves to avoid races and reduce save frequency.
- Fix: Wrap cache operations in a `CacheIO` actor and debounce `.cfg` saves.

5) Security: permissive TLS handling (risk)
- Issue: Challenge handler accepts any trust.
- Why it matters: Weakens transport security and can break under ATS/pinning scenarios.
- Fix: Remove permissive handling; allow default behavior or expose an optional evaluator hook.

6) Safe file naming for URLs without extension (correctness)
- Issue: Potential crash/incorrect extension derivation for extensionless URLs.
- Why it matters: Ensures consistent cache file paths and avoids runtime errors.
- Fix: Derive extension from MIME type or fallback to `mp4`.

---

## Concrete Changes

### 1) Move URLSession delegates off main

Create a shared session in `VideoDownloadManager`:
```swift
public actor VideoDownloadManager {
    public static let shared = VideoDownloadManager()

    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "GSPlayer.URLSession.delegate"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let sessionDelegate = VideoDownloaderSessionDelegateHandler(delegate: nil)

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: delegateQueue)
    }()

    // expose accessor for handlers (if needed)
    func sharedSession() -> URLSession { session }
}
```

Update `VideoDownloaderHandler` to use the manager’s session:
```swift
// instead of creating a new URLSession with .main delegate queue
task = await VideoDownloadManager.shared.sharedSession().dataTask(with: urlRequest)
task?.resume()
```

### 2) Centralize scheduling hooks in the manager

In `VideoDownloadManager`, maintain entries and apply priorities to tasks:
```swift
extension VideoDownloadManager {
    struct Entry { var priority: Float; var pins: [String: Float] }
    private var entries: [URL: Entry] = [:]
    private var maxActive = 3
    private var perHost = 2

    public func setConcurrency(maxActive: Int, perHost: Int) { self.maxActive = maxActive; self.perHost = perHost; reschedule() }
    public func setPriority(for url: URL, priority: Float) { ensure(url); entries[url]!.priority = priority; reschedule() }
    public func pin(url: URL, scope: String, priority: Float) { ensure(url); entries[url]!.pins[scope] = priority; reschedule() }
    public func unpin(url: URL, scope: String) { entries[url]?.pins.removeValue(forKey: scope); reschedule() }

    private func ensure(_ url: URL) { if entries[url] == nil { entries[url] = Entry(priority: 0.2, pins: [:]) } }
    private func effectivePriority(_ e: Entry) -> Float { max(e.priority, e.pins.values.max() ?? 0) }
    private func reschedule() { /* choose top-N by effective priority per host, set task.priority or suspend/resume */ }
}
```

Pass priority into tasks:
```swift
// When creating a task for url
task?.priority = URLSessionTask.defaultPriority // set proportionally e.g., 0.0..1.0 → 0.0..1.0
```

### 3) AsyncStream progress

Inside `VideoDownloadManager`:
```swift
public struct DownloadProgress: Sendable {
    public let url: URL
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let priority: Float
}

private var continuations: [URL: [AsyncStream<DownloadProgress>.Continuation]] = [:]

public func progressStream(for url: URL) -> AsyncStream<DownloadProgress> {
    AsyncStream { continuation in
        if continuations[url] == nil { continuations[url] = [] }
        continuations[url]?.append(continuation)
    }
}

private var lastEmit: [URL: CFTimeInterval] = [:]
internal func publish(_ p: DownloadProgress) {
    let now = CFAbsoluteTimeGetCurrent()
    let last = lastEmit[p.url] ?? 0
    guard now - last > 0.1 else { return } // ~10 Hz
    lastEmit[p.url] = now
    continuations[p.url]?.forEach { $0.yield(p) }
}
```

From `VideoDownloaderHandler`, send updates:
```swift
let progress = DownloadProgress(url: url, receivedBytes: Int64(startOffset), expectedBytes: Int64(cacheHandler.configuration.info?.contentLength ?? 0), priority: await VideoDownloadManager.shared.currentPriority(for: url))
await VideoDownloadManager.shared.publish(progress)
```

### 4) CacheIO actor usage and debounced saves

Introduce a debounced save in `CacheIO`:
```swift
actor CacheIO {
    private let handler: VideoCacheHandler
    private var pendingSave = false
    private var lastSave: CFAbsoluteTime = 0

    init(url: URL) throws { self.handler = try VideoCacheHandler(url: url) }

    func cache(data: Data, for range: NSRange) -> Bool { handler.cache(data: data, for: range) }
    func cachedData(for range: NSRange) -> Data { handler.cachedData(for: range) }
    func set(info: VideoInfo) { handler.set(info: info) }

    func saveDebounced() {
        pendingSave = true
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSave > 0.25 { saveNow() }
    }

    func saveNow() {
        guard pendingSave else { return }
        handler.save()
        pendingSave = false
        lastSave = CFAbsoluteTimeGetCurrent()
    }
}
```

Use `saveDebounced()` on each chunk and `saveNow()` at completion/cancel.

### 5) Security: remove permissive TLS

In `VideoDownloaderHandler` delegate:
```swift
func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(.performDefaultHandling, nil)
}
```

Optionally expose:
```swift
public var customAuthChallengeHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
```

### 6) Safe file naming for extensionless URLs

In `VideoCacheManager.cachedFilePath(for:contentType:)`:
```swift
let ext: String = {
    let p = url.pathExtension
    if !p.isEmpty { return p }
    if let mime = contentType, let ut = UTType(mimeType: mime), let e = ut.preferredFilenameExtension { return e }
    return "mp4"
}()
```

---

## Logging (add to GSPlayer code, throttled)
- 📡 session lifecycle and configuration
- 🎯 priority set/pin/unpin and reschedules
- 💾 fragment writes and `.cfg` saves (debounced)
- 🧮 progress emissions (10 Hz)
Example: `print("🎯 setPriority url=\(url.lastPathComponent) → \(priority)")`

---

## Acceptance Criteria
- No main-thread delegate callbacks; UI remains smooth.
- `VideoDownloadManager` controls a single session and applies priorities to tasks; pause/resume supported.
- `progressStream(for:)` delivers steady updates; NotificationCenter (if still present) is secondary.
- All disk writes go through `CacheIO`; saves are debounced and safe.
- No permissive TLS; default handling or custom evaluator only.
- Safe cache paths for extensionless URLs.

---

## Validation Plan
- Instrument logs (🎯, 📡, 💾, 🧮) and verify cadence.
- Stress test multiple concurrent downloads with priority changes; ensure lower-priority tasks yield.
- Force-close mid-download; relaunch and verify resume from fragments.
- Confirm no UI stutters while scrolling grid and playing detail.


