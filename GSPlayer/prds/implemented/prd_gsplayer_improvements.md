## GSPlayer vNext PRD — Thread-safe, Priority-aware, Resumable Video Caching and Prefetching

### Goals
- iOS 17+ only: Swift Concurrency-first design; no GCD-based app-level fallbacks. Prefer `AsyncStream` for progress, `async/await` for control APIs.
- Make GSPlayer fully thread-safe: heavy I/O, networking, parsing, and notifications must not run on the main thread.
- Add first-class, priority-aware downloads: 0.0…1.0 per URL, with pause/resume and dynamic reprioritization.
- Provide scalable prefetching that cooperates with active playback.
- Preserve resumable, fragment-based persistent caching across app relaunches; continue where we left off.
- Keep GSPlayer as an SPM package and preserve existing public surface area as much as possible.
- Keep `ViralGen/Utils/VideoPlayer.swift` as the only SwiftUI bridge in the app layer.

### Non-goals
- Background downloads while the app is terminated. We will resume on next launch using persisted fragments, not use a background URLSession.
- Full-featured HLS playlist management. We continue to stream HLS via AVFoundation pass-through.
- Legacy GCD-based fallbacks for pre-iOS 17.

---

## Current Assessment (What GSPlayer does today)

- Fragment caching
  - Uses `VideoCacheHandler` with a sparse file plus a JSON sidecar (`.cfg`) to track downloaded `NSRange` fragments.
  - Range packaging size is 512 KB (`packageLength`).
  - `actions(for:)` computes a local/remote action plan per AVAsset byte request.

- URL indirection for resource loader
  - `URL.constructed` prefixes a loader scheme and optionally appends a temporary extension (`mp4`) so `AVAssetResourceLoader` triggers.
  - `URL.deconstructed` restores the original URL when handling requests.

- Networking
  - `VideoDownloaderHandler` builds `URLSessionDataTask` per remote action with a custom `Range` header.
  - Current session is created with `.ephemeral` but bound to `.main` delegate queue, causing heavy work on the main thread.

- Threading and callbacks
  - `URLSession` delegate methods, file I/O (`cache(data:for:)`, `save()`), and `NotificationCenter` posts can occur on the main thread.
  - `objc_sync_enter/exit` protects file handles, but higher-level state is not actor-isolated.

- Persistence and resume
  - Partially downloaded cache files and `.cfg` persist in `Caches/GSPlayer/` and are reused on next run.
  - On relaunch, the first request for a URL reuses existing fragments and continues where it left off.

- Limitations and issues
  - Main-thread delegate queue and file I/O risk jank.
  - No explicit per-URL priority model; limited pause/resume controls; no cross-URL scheduling.
  - Notification-driven progress lacks per-URL async streams and can be chatty.
  - Potential crash when original URL has no path extension: `appendingPathExtension(url.pathExtension)!` can be nil for empty extension.
  - TLS challenge handler trusts all servers; security hardening recommended.

---

## Proposed Architecture (vNext)

### Concurrency model (simplified for iOS 17+)
- Swift Concurrency-only public surface: control methods are `async`, progress delivered via `AsyncStream`.
- Two core components to reduce complexity:
  - VideoDownloadManager actor: single orchestration point containing scheduling, a shared URLSession, progress coalescing, and prefetch entry points.
  - CacheIO actor: exclusive owner of file handles and sidecar saves; serializes disk I/O.
  - Note: `URLSession` still uses an internal non-main `OperationQueue` for delegate callbacks; this is an implementation detail and does not leak GCD into app code.

### URLSession and threading
- Replace `.main` delegate queue with a dedicated `OperationQueue` (QoS .utility, `maxConcurrentOperationCount = 1`) for delegate callbacks.
- Use `URLSessionConfiguration.default` (not background) for normal streaming; set:
  - `waitsForConnectivity = true`
  - `multipathServiceType = .handover`
  - `httpMaximumConnectionsPerHost = 6` (tunable)
  - `timeoutIntervalForRequest = 60`, `timeoutIntervalForResource = 120`
- Ensure all disk I/O and progress computation happens off main; the SwiftUI bridge dispatches to main only for UI updates.

### Priority-aware scheduling (inside VideoDownloadManager)
- Each URL gets a priority [0.0, 1.0]. Effective priority = max(pinnedScopes.values + basePriority, 0).
- Policies:
  - Weighted fair scheduling across active URLs by priority.
  - Max concurrent remote actions: global limit (e.g., 3) and per-host limit (e.g., 2).
  - Reprioritization updates `URLSessionTask.priority`; low-priority tasks may be suspended.
- Public API (in SPM) exposed by `VideoDownloadManager` (see below).

### Prefetching that cooperates with playback
- Implemented as a method on `VideoDownloadManager`:
  - `prefetch(urls:byteCount:priority:)` with conservative defaults.
  - Cooperates with scheduling; capped per-URL; skipped when already cached.

### Cache I/O and persistence
- Convert `VideoCacheHandler` into/behind a `CacheIO` actor to serialize access to file handles and sidecar saves.
- Reduce `save()` frequency:
  - Debounce saves (e.g., 250–500ms) and force-save on task completion/cancel.
  - Persist last fragment write time for recovery diagnostics.
- Fix extensionless URL crash:
  - Derive file extension from `URL.pathExtension` if present; else from MIME (`Content-Type`); else fall back to `mp4`.
  - Keep hash of `absoluteString` for the base filename to maintain identity.

### Security and robustness
- Remove permissive TLS challenge handler. Use default handling, or allow optional user-provided evaluator.
- Validate `Content-Range` responses; reissue requests on mismatch; back off with exponential delays.
- Network adaptivity (optional): integrate `NWPathMonitor` to lower concurrency on cellular/poor networks.

### Progress reporting
- Introduce `DownloadProgress { url, receivedBytes, expectedBytes?, priority }` in SPM.
- Provide `progressStream(for url: URL) -> AsyncStream<DownloadProgress>` directly from `VideoDownloadManager`.
- Optionally keep NotificationCenter posts for backwards compatibility, but `AsyncStream` is the primary API.

### Simplicity and justification
- Consolidate scheduling, URLSession ownership, progress coalescing, and prefetch entry points into a single `VideoDownloadManager` actor to minimize mental overhead.
- Keep `CacheIO` actor separate to guarantee exclusive file-handle ownership and clear separation of concerns (disk vs network/scheduling).
- Avoid extra actors (`SessionManager`, `ProgressCenter`, `VideoPrefetcher`) to reduce indirection and code volume while retaining clarity.

### AVResourceLoader integration
- Maintain existing `constructed/deconstructed` logic but handle no-extension URLs safely end-to-end.
- Recompute `actions(for:)` after each fragment completes to opportunistically serve more from local cache.

---

## Public APIs (SPM) — Additions (non-breaking)

```swift
public struct DownloadProgress: Sendable {
    public let url: URL
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let priority: Float
}

public actor VideoDownloadManager {
    public static let shared = VideoDownloadManager()
    public func setPriority(for url: URL, priority: Float)
    public func pin(url: URL, scope: String, priority: Float)
    public func unpin(url: URL, scope: String)
    public func pause(url: URL)
    public func resume(url: URL)
    public func setConcurrency(maxActive: Int, perHost: Int)
    public func isDownloading(url: URL) -> Bool
    public func prefetch(urls: [URL], byteCount: Int, priority: Float)
    public func progressStream(for url: URL) -> AsyncStream<DownloadProgress>
}

public enum VideoCacheManager {
    public static func cachedFilePath(for url: URL, contentType: String? = nil) -> String
}
```

Backward compatible updates:
- `VideoDownloader`/`VideoDownloaderHandler` delegate callbacks move off main; behavior preserved.
- `VideoPreloadManager.shared.set(waiting:)` remains, but internally delegates to `VideoPrefetcher` with default priority.

---

## Internal Design Sketches (SPM)

### VideoDownloadManager (session + scheduler, non-main delegate queue)
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
    // scheduling state, entries, pins, and progress streams live here
}
```

### Cache I/O actor and safer file naming
```swift
import UniformTypeIdentifiers

actor CacheIO {
    private let handler: VideoCacheHandler // or inline handles; single-threaded behind actor
    init(url: URL) throws { self.handler = try VideoCacheHandler(url: url) }
    func cache(data: Data, for range: NSRange) -> Bool { handler.cache(data: data, for: range) }
    func cachedData(for range: NSRange) -> Data { handler.cachedData(for: range) }
    func set(info: VideoInfo) { handler.set(info: info) }
    func save() { handler.save() }
}

extension VideoCacheManager {
    public static func cachedFilePath(for url: URL, contentType: String? = nil) -> String {
        let base = directory.appendingPathComponent(url.absoluteString.md5)
        let ext: String = {
            if let p = url.pathExtension, !p.isEmpty { return p }
            if let mime = contentType, let ut = UTType(mimeType: mime), let e = ut.preferredFilenameExtension { return e }
            return "mp4"
        }()
        return base.appendingPathExtension(ext)!
    }
}
```

### Priority-aware scheduling (outline inside manager)
```swift
extension VideoDownloadManager {
    struct Entry { var priority: Float; var pins: [String: Float]; var state: State /* + task refs */ }
    enum State { case idle, running, paused }
    private var entries: [URL: Entry] { get async { /* stored */ } }
    private var maxActive = 3
    private var perHost = 2
    public func setConcurrency(maxActive: Int, perHost: Int) { self.maxActive = maxActive; self.perHost = perHost; reschedule() }
    public func setPriority(for url: URL, priority: Float) { ensure(url); entries[url]!.priority = priority; reschedule() }
    public func pin(url: URL, scope: String, priority: Float) { ensure(url); entries[url]!.pins[scope] = priority; reschedule() }
    public func unpin(url: URL, scope: String) { entries[url]?.pins.removeValue(forKey: scope); reschedule() }
    public func pause(url: URL) { /* suspend tasks, update state */ }
    public func resume(url: URL) { /* resume tasks */ }
    private func effectivePriority(_ e: Entry) -> Float { max(e.priority, e.pins.values.max() ?? 0) }
    private func reschedule() { /* choose top-N by effectivePriority per host, adjust task.priority/suspend/resume */ }
    private func ensure(_ url: URL) { if entries[url] == nil { entries[url] = Entry(priority: 0.2, pins: [:], state: .idle) } }
}
```

### Progress Streams (AsyncStream)
```swift
extension VideoDownloadManager {
    public func progressStream(for url: URL) -> AsyncStream<DownloadProgress> { /* per-URL stream */ }
    private func publish(_ p: DownloadProgress) { /* coalesce & send */ }
}
```

---

## Integration Guidance (App Layer)

### `VideoPlayer.swift` (SwiftUI bridge)
- No breaking API changes. Internally, ensure any state callbacks dispatch to main for UI updates.
- When the bridge starts playback for a URL, set base priority to a high value (e.g., 0.8) via scheduler and unpin on stop.
- Seeking remains unchanged; range loader continues to work.

Example (inside `updateUIView` or `onAppear`):
```swift
Task { await VideoDownloadScheduler.shared.setPriority(for: url, priority: 0.8) }
```

### `ExploreContentView.swift`
- Grid cells:
  - On appear: `setPriority(url: video, 0.6)` and subscribe to `progressStream(for:)` to render progress.
  - On disappear: `setPriority(url: video, 0.2)`.
- Detail view:
  - On appear: `pin(url: scope: "detailPlayback", priority: 1.0)`; on disappear: `unpin(...)`.
- Replace usages of `VideoCacheWorker` with GSPlayer scheduler and progress streams.

Sketch:
```swift
// onAppear in cell for video URL
Task { await VideoDownloadManager.shared.setPriority(for: url, priority: isActive ? 0.6 : 0.2) }

// progress
Task { for await p in VideoDownloadManager.shared.progressStream(for: url) { /* update state */ } }

// detail view
.onAppear { Task { await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0) } }
.onDisappear { Task { await VideoDownloadManager.shared.unpin(url: url, scope: "detailPlayback") } }
```

### `ExploreService.swift`
- Use `VideoPrefetcher.shared.prefetch(urls:priority:)` with batches computed by your weighted-diagonal logic.
- Keep image and video prefetch pipelines concurrent; set video prefetch priority around 0.2–0.4 so they yield to interactive playback.

Sketch:
```swift
async let videoPrefetch: Void = VideoDownloadManager.shared.prefetch(urls: videoURLs, byteCount: 1_048_576, priority: 0.3)
```

---

## Persistence and Resume Semantics
- Current fragment model already resumes on next launch when the same URL is requested.
- Enhancements:
  - Startup scan: enumerate `Caches/GSPlayer` and read `.cfg` to identify incomplete assets; optionally schedule low-priority prefetch to finish top-N.
  - Persist pinned scopes (optional) only while app is running; do not restore pins on next launch.

Conclusion: After a force-close, previously written fragments are reused and downloads continue where they left off once the app asks for the URL again. With startup scan, we can proactively continue unfinished items.

---

## Security Hardening
- Remove unconditional trust in `urlSession(_:didReceive:challenge:)`.
- Optionally expose a hook for custom headers and TLS pinning from the host app.

---

## Performance & Tuning
- Package size: keep `packageLength = 512 KB`; expose as a tunable constant.
- Debounce sidecar saves to <= 4 Hz; always save at task finish.
- Coalesce progress notifications to 10 Hz per URL.
- Default concurrency: 3 active remote actions (per-host 2).

---

## Migration Plan
1. Introduce new actors and APIs in GSPlayer SPM; keep existing APIs.
2. Switch `URLSession` to non-main delegate queue; audit all main-thread affinity.
3. Implement scheduler and wire `VideoDownloaderHandler` to respect task priority/suspend/resume.
4. Add `VideoPrefetcher` and ProgressCenter.
5. Fix extensionless URL handling in `VideoCacheManager.cachedFilePath`.
6. Replace app-level `VideoCacheWorker` calls with scheduler/prefetcher in `ExploreContentView.swift` and `ExploreService.swift`.
7. Regression test playback, seeking, and caching on Wi‑Fi/cellular.

---

## Test Plan
- Unit tests
  - `actions(for:)` correctness for overlapping/adjacent fragments.
  - `cachedFilePath(for:contentType:)` for URLs with/without extensions and various MIME types.
  - Scheduler fairness and reprioritization (simulated tasks).
- Integration tests
  - Play, pause, seek with partial cache; verify continued downloads and playback.
  - Prefetch batches while playing another video; ensure interactive playback remains smooth.
  - Force-close mid-download; relaunch and ensure resume from previous fragments.

---

## Future Work (optional)
- Background prefetch using a separate background `URLSession` for selected assets when the app is in background (not terminated), gated by OS policies.
- Network-aware adaptation via `NWPathMonitor`.
- Telemetry hooks for success rates and average throughput.

---

## Appendix — Notable Code Cleanups
- Remove redundant `seekToEnd()` before `seek(toFileOffset:)` in `VideoCacheHandler.cache(data:for:)`.
- Replace repeated `save()` calls with debounced saves.
- Move `NotificationCenter` posts off main; dispatch back to main only in the SwiftUI bridge.
- Tighten error reporting with `NSURLError` codes and retry/backoff.


