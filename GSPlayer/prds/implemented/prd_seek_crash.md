### GSPlayer crash analysis PRD — EXC_BAD_ACCESS while seeking in detail view

- **Symptom**: App crashes while scrubbing/seeking a partially cached video in Explore detail.
- **Crash site**: Accessing per-task delegate map in the URLSession delegate handler.

```915:922:PRD/projectStructure/GSPlayer.md
if let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate { //it happenned here:Thread 2: EXC_BAD_ACCESS (code=1, address=0x10) 
    delegate.urlSession(session, task: task, didCompleteWithError: error)
}
unregister(task: task)
Task { [tid] in
    await VideoDownloadManager.shared.untrack(taskIdentifier: tid)
}
```

Related lifecycle points (cancel/dispose paths triggered by scrubbing):

```653:664:PRD/projectStructure/GSPlayer.md
deinit {
    cancel() //Enqueued from com.apple.main-thread (Thread 1)
}
func cancel() {
    task?.cancel() //Enqueued from com.apple.main-thread (Thread 1)
    isCancelled = true
}
```

```1716:1723:PRD/projectStructure/GSPlayer.md
public func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    guard let url = loadingRequest.url, let loader = loaderMap[url] else { return }
    loader.remove(request: loadingRequest) //Enqueued from com.apple.main-thread (Thread 1)
}
```


### Root cause

- **Data race on non-thread-safe maps in `VideoDownloaderSessionDelegateHandler`**:
  - The dictionaries `taskDelegates` and `buffers` are mutated from different threads without synchronization.
  - Delegate callbacks run on the shared URLSession’s `delegateQueue` (serial), but:
    - `register(task:delegate:)` is called from the `VideoDownloadManager` actor’s context (not the `delegateQueue`).
    - `unregister(task:)` is called from within delegate callbacks (on `delegateQueue`).
  - Concurrent access/mutation of Swift dictionaries is undefined behavior → memory corruption → EXC_BAD_ACCESS when reading `taskDelegates[tid]`.

- **Why scrubbing makes it easy to hit**:
  - Seeking triggers a flurry of `AVAssetResourceLoader` requests and cancels.
  - Cancels cause `VideoRequestLoader.finish()`; some paths also cancel the underlying `URLSessionDataTask` and drop references:
    - `VideoDownloader.cancel()` sets `downloaderHandler = nil` (deinits handler).
    - Delegate map still holds a weak pointer to that handler until `didCompleteWithError` runs.
  - Rapidly creating new tasks (register) while others are finishing (didComplete → unregister) amplifies concurrent map access.

- **Weak pointer is not the issue**:
  - Using `WeakBox` means a deallocated delegate should become `nil` safely.
  - The crash occurs before or during fetching from the dictionary because the dictionary itself is being concurrently mutated.


### Contributing factors (less critical but worth hardening)

- `VideoDownloaderHandler.deinit` calls `cancel()` which calls `task?.cancel()`; this can accelerate a “complete callback” racing with deallocation. Safe if maps are synchronized.
- `VideoLoadManager.shared.invalidate(url:)` on disappear (detail view) force-disposes loader state; again, safe if maps are synchronized.
- `VideoDownloaderSessionDelegateHandler.callbackBuffer` and other methods read and write `buffers[tid]` without any lock; same race class.


### Fix strategy

Make all access to `taskDelegates` and `buffers` thread-safe by serializing on a single execution context. Two equivalent approaches:

- Option A (recommended): Route all registration/unregistration and map access through the same `delegateQueue` already used by `URLSession`.
- Option B: Add a private lock (or serial `DispatchQueue`) in `VideoDownloaderSessionDelegateHandler` and guard every access to the maps.

Using both (A + B) gives belt-and-suspenders safety with minimal risk and code churn.

#### 1) Ensure registration runs on the URLSession delegate queue

Modify the manager’s registration API so mutations happen on the same queue the delegate callbacks run on.

```999:1040:PRD/projectStructure/GSPlayer.md
public actor VideoDownloadManager {
    // ...
    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "GSPlayer.URLSession.delegate"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let sessionDelegate = VideoDownloaderSessionDelegateHandler()

    public func sharedSession() -> URLSession { session }

    // NEW: marshal registration onto the delegateQueue to avoid cross-thread map access
    func register(task: URLSessionTask, delegate: VideoDownloaderSessionDelegateHandlerDelegate) {
        delegateQueue.addOperation { [sessionDelegate] in
            sessionDelegate.register(task: task, delegate: delegate)
        }
    }
}
```

No other call sites change; callers keep `await VideoDownloadManager.shared.register(task:delegate:)` and you gain single-threaded mutation aligned with delegate callbacks.

#### 2) Add a lock inside the delegate handler and guard the maps

This protects against any remaining incidental cross-thread access (now unlikely after step 1), and also future edits.

```855:881:PRD/projectStructure/GSPlayer.md
class VideoDownloaderSessionDelegateHandler: NSObject {
    // Global auth challenge override. If nil, default handling is used.
    var authChallengeHandler: ((URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?

    private class WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    // Per-task delegate routing and buffers (NON-thread-safe → protect with lock)
    private var taskDelegates: [Int: WeakBox<AnyObject>] = [:]
    private var buffers: [Int: Data] = [:]

    // NEW: lock for maps
    private let lock = NSLock()

    override init() { }

    func register(task: URLSessionTask, delegate: VideoDownloaderSessionDelegateHandlerDelegate) {
        lock.lock()
        taskDelegates[task.taskIdentifier] = WeakBox(delegate)
        buffers[task.taskIdentifier] = Data()
        lock.unlock()
    }

    func unregister(task: URLSessionTask) {
        lock.lock()
        taskDelegates.removeValue(forKey: task.taskIdentifier)
        buffers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }
}
```

Guard reads/writes in delegate methods:

```883:922:PRD/projectStructure/GSPlayer.md
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let tid = dataTask.taskIdentifier
    // READ UNDER LOCK, then release before calling out
    lock.lock()
    let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate
    lock.unlock()

    if let delegate {
        delegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    } else {
        completionHandler(.cancel)
    }
}

func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let tid = dataTask.taskIdentifier
    lock.lock()
    if buffers[tid] == nil { buffers[tid] = Data() }
    buffers[tid]?.append(data)
    let shouldFlush = (buffers[tid]?.count ?? 0) > bufferSize
    lock.unlock()
    if shouldFlush { callbackBuffer(session: session, dataTask: dataTask) }
}

func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let tid = task.taskIdentifier

    // Flush any remaining buffer before delivering completion
    if error == nil, let dt = task as? URLSessionDataTask {
        lock.lock()
        let hasPending = (buffers[tid]?.count ?? 0) > 0
        lock.unlock()
        if hasPending { callbackBuffer(session: session, dataTask: dt) }
    }

    // Snapshot delegate under lock, then release lock before calling out
    lock.lock()
    let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate
    lock.unlock()

    delegate?.urlSession(session, task: task, didCompleteWithError: error)

    unregister(task: task)
    Task { [tid] in
        await VideoDownloadManager.shared.untrack(taskIdentifier: tid)
    }
}
```

And in the helper:

```926:935:PRD/projectStructure/GSPlayer.md
private func callbackBuffer(session: URLSession, dataTask: URLSessionDataTask) {
    let tid = dataTask.taskIdentifier
    lock.lock()
    guard
        let buffer = buffers[tid],
        let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate
    else { lock.unlock(); return }

    let range: Range<Int> = 0 ..< buffer.count
    let chunk = buffer.subdata(in: range)
    buffers[tid]?.replaceSubrange(range, with: [], count: 0)
    lock.unlock()

    delegate.urlSession(session, dataTask: dataTask, didReceive: chunk)
}
```

Notes:
- Always minimize time spent holding the lock; never call out to delegates while locked.
- With step 1, these code paths are all on the same `delegateQueue`, but the lock guarantees safety if a future change accidentally crosses threads again.


### Optional hardening

- Make `VideoDownloaderHandler.cancel()` idempotent and guard `task` access with a lightweight atomic or main-queue hop if you ever interact with UI there. Current code is acceptable once the map races are fixed.
- Consider explicitly unregistering the task in `cancel()` (by posting an operation on the `delegateQueue`) if you want faster cleanup; not required for correctness after the fixes above.
- Keep `delegateQueue.maxConcurrentOperationCount = 1` (already set) to serialize delegate callbacks for clearer ordering and easier reasoning.


### Why this resolves your crash

- All map mutations and reads become serialized:
  - `register` runs on the exact same `delegateQueue` as `URLSession` callbacks.
  - Even if any call crosses threads, the lock prevents concurrent access to the dictionaries.
- When a `VideoDownloaderHandler` is deallocated due to scrubbing/cancel:
  - The weak entry turns `nil` safely.
  - The read guarded by lock sees `nil` and simply skips calling back into a dead delegate.
  - No corrupt dictionary state → no EXC_BAD_ACCESS.


### Minimal tests/validation

- Reproduce: Start a video in `ExploreDetailView`, scrub aggressively across unbuffered ranges, dismiss/present repeatedly.
- Observe: No crash at `urlSession(_:task:didCompleteWithError:)`. Delegate calls stop cleanly after cancellation.
- Run with Thread Sanitizer to confirm no data races on `taskDelegates` or `buffers`.
- Logging: Keep the “🎥 [GS] …” logs and add one-time logging in register/unregister to confirm ordering on the same thread/queue.


### Touch points in your app

- `ExploreContentView.swift`: Scrubbing and presentation/dismissal triggers loader create/cancel; safe after fix.
- `VideoPlayer.swift`: `onDisappear` invalidates loader; pin/unpin/prefetch interacts with download manager; safe after fix. No changes required here.
- `ExploreService.swift` / `ViralGenApp.swift`: Prefetch and GSPlayer configuration are fine. No changes required.


### Code sample — full combined snippet (reference)

Add the `delegateQueue.addOperation` registration and the `NSLock` guarded maps as shown above. Those are the only code changes needed.

If you prefer a single-queue design without a lock, you can drop the `NSLock` and strictly ensure every map access happens on `delegateQueue` (including `callbackBuffer`, `unregister`, and all URLSession delegate methods). The lock version is simpler to retrofit and robust to future edits.


- Fixed a crash caused by unsynchronized access to `taskDelegates`/`buffers` in `VideoDownloaderSessionDelegateHandler`.
- Solution: marshal `register(task:delegate:)` onto the URLSession `delegateQueue` and guard all map access with a lock; do not call delegates while holding the lock.
- No changes needed in `ExploreService.swift`, `ViralGenApp.swift`, or `VideoPlayer.swift`.