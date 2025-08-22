### PRD: Fix QoS Priority Inversion when changing GSPlayer download priorities

#### Context
- We integrate GSPlayer to prefetch/cache and play explore videos.
- UI triggers priority changes frequently (e.g., `ExploreDetailView` pin/unpin, grid cell appear/disappear, `VideoPlayer.updateUIView`).

#### Symptom
Thread Performance Checker warns about priority inversion when opening and then closing the detail view:

```
Thread Performance Checker: Thread running at User-initiated quality-of-service class waiting on a lower QoS thread running at Utility quality-of-service class.

Backtrace
0   ... URLSession.getAllTasksSync ...
1   ... VideoDownloadManager.applyPriority(to:)
2   ... VideoDownloadManager.setPriority(for:priority:)
3   ... VideoPlayer.updateUIView(...)

// and
0   ... URLSession.getAllTasksSync ...
1   ... VideoDownloadManager.applyPriority(to:)
2   ... VideoDownloadManager.unpin(url:scope:)
3   ... ExploreDetailView.onDisappear { unpin }
```

#### Root cause
- In `GSPlayer` (see our local copy `PRD/projectStructure/GSPlayer.md`), `VideoDownloadManager` calls a synchronous helper:

```swift
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

- This blocks the current thread until `URLSession.getAllTasks` completes. Our `URLSession` delegate queue is explicitly configured with QoS `.utility`. When a User-initiated UI task calls `setPriority`/`unpin`, the call runs on a higher QoS thread which then blocks, waiting for work performed on the lower-QoS delegate queue — classic QoS inversion.

#### Goals
- Eliminate blocking waits inside GSPlayer priority changes.
- Optionally align calling task QoS with networking work to avoid future inversions.
- Reduce priority churn from UI where easy.

---

### Fix 1 (Required): Make `getAllTasks` asynchronous and remove blocking

Replace the semaphore-based sync helper with an async version and await it from priority-changing APIs.

Edits in `GSPlayer` (our copy for reference: `PRD/projectStructure/GSPlayer.md`). These edits must be applied to the actual GSPlayer source in the SPM/fork used by the app.

1) Add async helper and remove `getAllTasksSync`:

```swift
@available(iOS 13.0, macOS 10.15, *)
private extension URLSession {
    func getAllTasksAsync() async -> [URLSessionTask] {
        await withCheckedContinuation { cont in
            getAllTasks { tasks in cont.resume(returning: tasks) }
        }
    }
}
```

2) Make `applyPriority`, `pause(url:)`, and `resume(url:)` async and use the async helper:

```swift
// inside actor VideoDownloadManager
private func applyPriority(to url: URL) async {
    guard let tids = urlToTaskIds[url] else { return }
    let eff = currentPriority(for: url)
    let tasks = await session.getAllTasksAsync()
    for tid in tids {
        if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
            task.priority = eff
        }
    }
}

public func pause(url: URL) async {
    guard let tids = urlToTaskIds[url] else { return }
    let tasks = await session.getAllTasksAsync()
    for tid in tids { tasks.first(where: { $0.taskIdentifier == tid })?.suspend() }
}

public func resume(url: URL) async {
    guard let tids = urlToTaskIds[url] else { return }
    let tasks = await session.getAllTasksAsync()
    for tid in tids { tasks.first(where: { $0.taskIdentifier == tid })?.resume() }
}
```

3) Make public APIs async and await the new async `applyPriority`:

```swift
public func setPriority(for url: URL, priority: Float) async {
    ensure(url)
    entries[url]!.priority = priority
    await applyPriority(to: url)
}

public func pin(url: URL, scope: String, priority: Float) async {
    ensure(url)
    entries[url]!.pins[scope] = priority
    await applyPriority(to: url)
}

public func unpin(url: URL, scope: String) async {
    entries[url]?.pins.removeValue(forKey: scope)
    await applyPriority(to: url)
}
```

Notes:
- On iOS 17+, prefer explicit async public APIs and `await` at call sites. This avoids hidden thread hops and keeps everything in structured concurrency. The key is to remove the synchronous `sem.wait()` entirely.

---

### Fix 2 (Optional): Align caller task QoS to Utility

Even after Fix 1, aligning task QoS avoids future inversions if third-party code blocks. Change our call sites to use detached tasks with `.utility` priority.

Edits in app code:

1) `ViralGen/Utils/VideoPlayer.swift` (inside `updateUIView`):

```swift
if play {
    Task(priority: .utility) {
        await VideoDownloadManager.shared.setPriority(for: url, priority: 0.8)
    }
}
```

2) `ViralGen/VideoGen/Views/Explore/ExploreContentView.swift`:

```swift
// In .onChange(of: selectedListId)
Task(priority: .utility) {
    let currentId = newValue
    let allLists = explore.lists.map { $0.id }
    for listId in allLists {
        guard let items = explore.itemsByListId[listId] else { continue }
        let pr: Float = (listId == currentId) ? 0.6 : 0.2
        for item in items where item.type == .video {
            if let s = item.videoUrl, let url = URL(string: s), !s.isEmpty {
                await VideoDownloadManager.shared.setPriority(for: url, priority: pr)
            }
        }
    }
}

// In ExploreGridCell.handleAppear()
Task(priority: .utility) {
    await VideoDownloadManager.shared.setPriority(for: url, priority: pr)
}

// In ExploreGridCell.handleDisappear()
Task(priority: .utility) {
    await VideoDownloadManager.shared.setPriority(for: url, priority: 0.2)
}
```

3) `ExploreDetailView` pin/unpin during appear/disappear:

```swift
.onAppear {
    play = true
    Task(priority: .utility) {
        await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0)
    }
}
.onDisappear {
    play = false
    Task(priority: .utility) {
        await VideoDownloadManager.shared.unpin(url: url, scope: "detailPlayback")
    }
}
```

---

### Fix 3 (Optional): Consider delegate queue QoS

Today the GSPlayer shared `URLSession` uses:

```swift
delegateQueue.qualityOfService = .utility
```

If you expect priority changes to be driven by user interactions frequently, it’s reasonable to choose `.userInitiated` here. However, this is not required if we remove the blocking wait (Fix 1).

```swift
private lazy var delegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "GSPlayer.URLSession.delegate"
    q.qualityOfService = .userInitiated // optional tweak
    q.maxConcurrentOperationCount = 1
    return q
}()
```

---

### Fix 4 (Nice-to-have): Reduce churn from many `setPriority` calls

When switching lists we may call `setPriority` for dozens of URLs. Two improvements:

- Debounce list-level priority updates by ~50–100ms.
- Add a batching API in `VideoDownloadManager` to apply one `getAllTasks` scan per batch.

Example batching API (inside the actor):

```swift
public func setPriorities(_ changes: [(URL, Float)]) {
    for (url, p) in changes { ensure(url); entries[url]!.priority = p }
    Task {
        let tasks = await session.getAllTasksAsync()
        for (url, _) in changes {
            guard let tids = urlToTaskIds[url] else { continue }
            let eff = currentPriority(for: url)
            for tid in tids { tasks.first(where: { $0.taskIdentifier == tid })?.priority = eff }
        }
    }
}
```

---

### Testing plan
- Reproduce: open a video detail, then dismiss it to trigger `unpin`. Previously this emitted TPC warnings.
- After Fix 1, run with Thread Performance Checker enabled — warnings should disappear.
- Verify functionality: priorities still affect new and active URLSessionDataTasks (observe via logs and download behavior).

### Rollout
- Patch GSPlayer fork/SPM with Fix 1 (required). Optionally apply Fix 2–4 in our app.
- QA on device with TPC enabled.

### Risk
- Low: changes are internal to task discovery/priority application. No API surface break if we keep public methods non-async and hop internally via `Task { await ... }`.


