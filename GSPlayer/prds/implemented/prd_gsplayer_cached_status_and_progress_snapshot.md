## PRD: GSPlayer – Accurate Cached Status API + Initial Progress Snapshot

### Context
- Explore grid cells show cached percentage only while downloading. After app restarts or when an item is already fully cached, the UI often shows 0% until new network activity happens.
- The SwiftUI side subscribes to a download progress stream, but the stream does not emit an initial snapshot of the on-disk cache; it only yields when new bytes arrive.

### Goals
- Provide a lightweight, synchronous-appearance API (async under the hood) to query cached bytes and expected length using GSPlayer’s on-disk configuration.
- Make the progress stream emit an initial snapshot immediately upon subscription so the UI can render accurate percent without waiting for network.
- Keep logging lightweight and gated to DEBUG.

### Non-Goals
- No change to cache file format. We continue using `VideoCacheConfiguration` with persisted `info: VideoInfo` and `fragments`.
- No change to scheduling/priorities.

---

### Proposed API Additions (Actor-safe)

Add a small value type to expose cache status:

```swift
public struct CachedStatus: Sendable {
    public let url: URL
    public let downloadedBytes: Int64
    public let expectedBytes: Int64?
    public var percent: Double {
        guard let expected = expectedBytes, expected > 0 else { return -1 }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(expected)))
    }
    public var isComplete: Bool {
        guard let expected = expectedBytes, expected > 0 else { return false }
        return downloadedBytes >= expected
    }
}
```

Add two APIs to `VideoDownloadManager`:

```swift
public func cachedStatus(for url: URL) -> CachedStatus

public func progressStream(for url: URL) -> AsyncStream<DownloadProgress>
// Behavior change: yield an initial snapshot immediately (derived from on-disk cache)
```

Rationale:
- `cachedStatus(for:)` lets the UI fetch an exact snapshot on view appear or app start, even with no active download tasks.
- Emitting an initial snapshot from `progressStream(for:)` removes UI races; subscribers will instantly receive the current cached state.

---

### Implementation Details

1) Implement `cachedStatus(for:)` using existing cache primitives:

```swift
// In VideoDownloadManager
public func cachedStatus(for url: URL) -> CachedStatus {
    // Best-effort: on-disk configuration may or may not exist yet
    let cfg = (try? VideoCacheManager.cachedConfiguration(for: url))
    let downloaded = Int64(cfg?.downloadedByteCount ?? 0)
    let exp = Int64(cfg?.info?.contentLength ?? 0)
    let expected: Int64? = exp > 0 ? exp : nil
    #if DEBUG
    print("🎥 [GS] 🧮 cachedStatus — recv=\(downloaded) exp=\(expected ?? -1) — \(url.lastPathComponent)")
    #endif
    return CachedStatus(url: url, downloadedBytes: downloaded, expectedBytes: expected)
}
```

2) Make `progressStream(for:)` yield an initial snapshot:

```swift
// In VideoDownloadManager
public func progressStream(for url: URL) -> AsyncStream<DownloadProgress> {
    return AsyncStream<DownloadProgress> { continuation in
        if progressContinuations[url] == nil { progressContinuations[url] = [] }
        progressContinuations[url]?.append(continuation)

        // NEW: Emit initial snapshot from on-disk cache so UI renders instantly.
        let cfg = try? VideoCacheManager.cachedConfiguration(for: url)
        let received = Int64(cfg?.downloadedByteCount ?? 0)
        let exp = Int64(cfg?.info?.contentLength ?? 0)
        let expected = exp > 0 ? exp : nil
        let pr = currentPriority(for: url)
        continuation.yield(DownloadProgress(url: url, receivedBytes: received, expectedBytes: expected, priority: pr))
    }
}
```

3) Optional log polish (DEBUG-only)
- Keep existing response and content-info prints.
- Add a concise print inside `cachedStatus(for:)` (above) and when `VideoDownloaderHandler` finishes (already logs progress/finish events).

---

### Edge Cases & Behavior
- If `contentLength` is unknown (`*` or missing), `expectedBytes` will be `nil`. The UI should display received bytes (e.g., "6.4 MB") rather than a percent.
- If there is no configuration yet, both received and expected will be 0/`nil`. The UI should render `0%` or `0 B` and update once downloads begin.
- When a video is fully cached, percent will compute to 100% on app start, since `downloadedByteCount` equals `contentLength` from the saved `VideoCacheConfiguration`.

---

### Acceptance Criteria
- Subscribing to `progressStream(for:)` immediately yields a value reflecting current on-disk cache state.
- Calling `cachedStatus(for:)` without any active network returns accurate bytes and expected length for all previously played/prefetched URLs.
- After killing and relaunching the app, grid cells can show accurate cached percentage for already cached videos without waiting for new network I/O.
- DEBUG logs show one short line per snapshot fetch (not spammy per frame).

---

### Rollout Plan
1) Implement APIs above in SPM GSPlayer code.
2) Update SwiftUI to:
   - call `cachedStatus(for:)` on cell appear to seed UI,
   - subscribe to `progressStream(for:)` for live updates.
3) Verify across: fresh install, after partial cache, and after full cache + relaunch.

### Test Plan
- Unit-ish actor tests (if feasible):
  - Seed a fake `VideoCacheConfiguration` file with `info.contentLength=10MB` and `fragments` totaling 4MB. Assert `cachedStatus(for:)` reports 4MB / 10MB.
  - Subscribe to `progressStream(for:)` and assert the first yield matches the same snapshot.
- Manual QA:
  - Prefetch 1 MB for N URLs → relaunch → verify grid shows ~1MB/length or ~10%.
  - Fully play one URL → relaunch → verify 100% shows instantly in grid and detail.


