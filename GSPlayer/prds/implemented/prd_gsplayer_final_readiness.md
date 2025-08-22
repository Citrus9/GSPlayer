## PRD — GSPlayer Final Readiness Review and Deltas

### Verdict
GSPlayer.md is close to integration-ready. Core improvements are in place: shared URLSession on a utility queue, CacheIO actor with debounced saves, `AsyncStream<DownloadProgress>`, and safe TLS default handling. However, two essential items remain before we integrate into `ExploreService.swift` and `ExploreContentView.swift`:

- Dynamic reprioritization of active tasks and proper pause/resume require a task registry in `VideoDownloadManager`.
- Prefetch deduplication and basic “in-flight” awareness (so we don’t start duplicate work and so `isDownloading(url:)` becomes meaningful).

The items below keep the design simple, readable, and justified for our use case.

---

## Required Deltas

### 1) Task Registry in `VideoDownloadManager` (enables reprioritization and pause/resume)

Why: Today `setPriority(for:)` updates internal state, but existing `URLSessionTask`s for that URL aren’t updated. We also cannot pause/resume without locating active tasks. A registry keyed by URL → taskIdentifiers (and the reverse) fixes this with minimal complexity.

Add to `VideoDownloadManager`:
```swift
// URL ↔︎ Task mapping
private var urlToTaskIds: [URL: Set<Int>] = [:]
private var taskIdToURL: [Int: URL] = [:]

public func track(task: URLSessionTask, for url: URL) {
    let tid = task.taskIdentifier
    if urlToTaskIds[url] == nil { urlToTaskIds[url] = [] }
    urlToTaskIds[url]?.insert(tid)
    taskIdToURL[tid] = url
}

public func untrack(taskIdentifier: Int) {
    if let url = taskIdToURL.removeValue(forKey: taskIdentifier) {
        urlToTaskIds[url]?.remove(taskIdentifier)
        if urlToTaskIds[url]?.isEmpty == true { urlToTaskIds.removeValue(forKey: url) }
    }
}

public func isDownloading(url: URL) -> Bool {
    return (urlToTaskIds[url]?.isEmpty == false)
}

// Apply new effective priority to all active tasks for URL
private func applyPriority(to url: URL) {
    guard let tids = urlToTaskIds[url] else { return }
    let eff = currentPriority(for: url)
    for tid in tids {
        if let task = session.getAllTasksSync().first(where: { $0.taskIdentifier == tid }) {
            task.priority = eff
        }
    }
}

// Helper to synchronously snapshot tasks inside actor
// (URLSession has async getAllTasks API; here we wrap it for actor use)
private extension URLSession {
    func getAllTasksSync() -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []
        let sem = DispatchSemaphore(value: 0)
        getAllTasks { arr in tasks = arr; sem.signal() }
        sem.wait()
        return tasks
    }
}
```

Wire into lifecycle:
```swift
// When creating a task (in VideoDownloaderHandler.processActions)
await VideoDownloadManager.shared.track(task: t, for: self.url)

// When a task completes (in VideoDownloaderSessionDelegateHandler)
await VideoDownloadManager.shared.untrack(taskIdentifier: task.taskIdentifier)
```

Update scheduling API to propagate immediately:
```swift
public func setPriority(for url: URL, priority: Float) {
    ensure(url)
    entries[url]!.priority = priority
    applyPriority(to: url)
}

public func pin(url: URL, scope: String, priority: Float) {
    ensure(url)
    entries[url]!.pins[scope] = priority
    applyPriority(to: url)
}

public func unpin(url: URL, scope: String) {
    entries[url]?.pins.removeValue(forKey: scope)
    applyPriority(to: url)
}
```

Implement pause/resume minimally:
```swift
public func pause(url: URL) {
    guard let tids = urlToTaskIds[url] else { return }
    for tid in tids {
        if let task = session.getAllTasksSync().first(where: { $0.taskIdentifier == tid }) {
            task.suspend()
        }
    }
}

public func resume(url: URL) {
    guard let tids = urlToTaskIds[url] else { return }
    for tid in tids {
        if let task = session.getAllTasksSync().first(where: { $0.taskIdentifier == tid }) {
            task.resume()
        }
    }
}
```

Notes:
- We keep the registry entirely inside the actor for safety.
- `getAllTasksSync()` uses a semaphore bridge. For iOS 17+, this is acceptable inside the actor context when used sparingly (small sets). If preferred, you can make `applyPriority`/`pause`/`resume` fully async using `await session.tasks` with an async wrapper.

### 2) Prefetch deduplication (avoid duplicate downloader work)

Why: `prefetch(urls:)` may start new downloads even when one is already in flight or sufficiently cached.

Change prefetch to consult registry and cache before starting:
```swift
public func prefetch(urls: [URL], byteCount: Int, priority: Float) {
    for url in urls {
        Task { [priority] in
            // Skip if actively downloading
            if await VideoDownloadManager.shared.isDownloading(url: url) { return }

            // Skip if enough is cached already
            if let cfg = try? VideoCacheManager.cachedConfiguration(for: url),
               cfg.downloadedByteCount >= byteCount {
                return
            }

            await VideoDownloadManager.shared.setPriority(for: url, priority: priority)
            do {
                let cacheHandler = try VideoCacheHandler(url: url)
                if cacheHandler.configuration.downloadedByteCount < byteCount {
                    let downloader = VideoDownloader(url: url, cacheHandler: cacheHandler)
                    downloader.download(from: 0, length: byteCount)
                }
            } catch { /* swallow prefetch errors */ }
        }
    }
}
```

This is intentionally minimal and keeps code readable.

---

## Optional, Nice-to-Have (Not blocking integration)

- Replace `DispatchSemaphore` bridge in `VideoDownloaderHandler.didReceive data` with a small, bounded work queue to avoid blocking the delegate thread when disk is slow. Current approach is safe but can reduce throughput.
- Expose a single togglable verbose logging function in SPM (e.g., `log("🎯 setPriority …")`).
- Content-Range validation and retry/backoff for robustness (keep simple: 1–2 retries with small delay).

---

## Acceptance Criteria After Deltas

- Calling `setPriority`, `pin`, or `unpin` immediately updates `URLSessionTask.priority` for any active tasks on that URL.
- Calling `pause`/`resume` suspends/resumes all active tasks for the URL.
- `prefetch` skips URLs already downloading or sufficiently cached, preventing duplicate downloader work.
- No main-thread URLSession delegate callbacks; UI remains smooth.

---

## Test Checklist

- Reprioritization: start a download at 0.2, then bump to 1.0 (detail view pin); verify task priority updates without restarting.
- Pause/Resume: pause a downloading URL and confirm no bytes progress for >1s; resume and confirm progress continues.
- Prefetch dedup: schedule prefetch for URL already downloading; prefetch should skip.
- Relaunch resume: partial fragments persist; requesting same URL continues.


