### PRD: Sustained, Grid‑Aware Video Prefetch (even when not watching)

- Owner: Explore
- Components: `ExploreService`, `ExploreContentView`, `ExploreGridCell`, `VideoDownloadManager` (GSPlayer)
- Goal date: ASAP

### 1) Background
- Images already prefetch continuously via `ExploreService` diagonal sweeps.
- Videos currently receive only small head prefetches:
  - Global diagonal batches in `ExploreService.prefetchMedia` call `prefetch(urls:byteCount:priority:)` with 1 MB.
  - Visible cells pin + prefetch 1–2 MB in `ExploreGridCell.handleAppear()`.
  - Detail view pins + prewarms 1 MB at priority 1.0.
- Result: when not in detail, downloads typically stall around 1–2 MB because nothing keeps increasing the prefetch target budget.

### 2) Problem statement
- We need videos to keep caching while the user is browsing the grid, not only when in detail.
- Active grid (selected list) should progress fastest, adjacent grids slower, others minimal or off.
- The diagonal sweep should be the default order to spread bandwidth across lists/items.

### 3) Key insight (what’s missing)
- `VideoDownloadManager.prefetch(urls:byteCount:priority:)` downloads up to the requested byteCount, then stops. It’s idempotent and safe to call repeatedly with larger byte budgets, which will fetch only missing ranges.
- We are missing a sustained scheduler that periodically raises the target budgets per URL based on context (active/adjacent/other) and diagonal order.

### 4) Desired behavior
- A foreground loop continues to raise budgets for videos:
  - Active grid: ramp from 2 MB → 4 MB → 6 MB → … up to a cap (e.g., 16–32 MB or full file).
  - Adjacent grids: ramp slower (e.g., 1 MB → 2 MB → 4 MB cap).
  - Other grids: keep a small head (0.5–1 MB) or no-op.
- Cell visibility keeps pinning priorities, but prefetch continues even when not looking at detail.
- Switching lists rebalances priorities and prefetch focus immediately.

### 5) High‑level design

- SPM (GSPlayer) provides only low‑level primitives: prefetch ranges by URL, set/batch priorities, pause/resume. It does not know about UI concepts like active/adjacent/other.
- SwiftUI app layer owns all policy and scheduling: diagonal ordering, budgets per context, loop cadence, and focus mode logic. You can change prioritization without touching SPM.

---

### 6) SPM‑side primitives (no policy)

Keep the SPM focused on generic operations. Add only small helpers that improve efficiency without encoding UI policy.

Additions to `VideoDownloadManager` (GSPlayer) — all generic:

```swift
// GSPlayer/SPM — VideoDownloadManager.swift

// 1) Batch prefetch with per‑URL budgets and priorities (coalesced)
public func prefetchBatch(_ updates: [(url: URL, byteCount: Int, priority: Float)]) async {
    // Coalesce duplicated URLs keeping the max(byteCount) and max(priority)
    var merged: [URL: (Int, Float)] = [:]
    for (u, b, p) in updates {
        let cur = merged[u]
        merged[u] = (max(b, cur?.0 ?? 0), max(p, cur?.1 ?? 0.0))
    }
    // Apply priorities, then prefetch
    await setPriorities(merged.map { ($0.key, $0.value.1) })
    for (u, (b, p)) in merged { await prefetch(urls: [u], byteCount: b, priority: p) }
}

// 2) Batch pause/resume helpers (thin wrappers)
public func pause(urls: [URL]) async { for u in urls { await pause(url: u) } }
public func resume(urls: [URL]) async { for u in urls { await resume(url: u) } }

// (No prefetchToEnd here — keep SPM policy‑free per app requirements)
```

These helpers do not encode any grouping or context. The app decides ordering, budgets, and when to call them.

---

### 7) SwiftUI/App‑side policy and scheduler

- Diagonal ordering and budgets live in `ExploreService` (you already have `computeWeightedDiagonalBatches`).
- A sustained loop in `ExploreService` raises budgets over time based on active/adjacent/other lists.
- `ExploreContentView` updates the service when `selectedListId` changes; the service adjusts priorities via `setPriorities` and continues the loop.
- Detail view implements focus mode entirely from the app (pins detail URL and temporarily suppresses others).

#### 7.1) Detail focus: ensure full bandwidth from the app layer

Add a convenience to get all video URLs in `ExploreService`:
```swift
// ExploreService.swift
@MainActor
func allVideoURLs() -> [URL] {
    lists.flatMap { itemsByListId[$0.id] ?? [] }
        .compactMap { $0.videoUrl }
        .compactMap(URL.init(string:))
}
```

Use it in `ExploreDetailView` to tilt bandwidth while keeping policy in SwiftUI:
```swift
// ExploreDetailView.swift
@Environment(ExploreService.self) private var explore

.onAppear {
    Task {
        // Pin focused URL at 1.0
        await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0)
        await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: 1_048_576, priority: 1.0)
        // Lower others to 0.1 for stronger focus (optional)
        let others = explore.allVideoURLs().filter { $0 != url }
        await VideoDownloadManager.shared.setPriorities(others.map { ($0, 0.1) })
    }
}
.onDisappear {
    Task {
        await VideoDownloadManager.shared.unpin(url: url, scope: "detailPlayback")
        // Restore grid priorities – the sustained loop will reapply on next pass
    }
}
```

If you need to be even more aggressive, temporarily pause others:
```swift
Task { await VideoDownloadManager.shared.pause(urls: others) }
// ... on disappear
Task { await VideoDownloadManager.shared.resume(urls: others) }
```

Keep your cell‑level pin + head prefetch as‑is.

---

### 8) App‑side sustained loop (canonical)
// Policy lives entirely here; SPM only provides primitives used by this loop.

### 8.1) Implementation outline

#### A) ExploreService — sustained prefetch loop and context
Add a lightweight loop that increases target budgets over time. This stays in the foreground (no background task needed) and cancels when Explore refreshes.

```swift
// ExploreService.swift additions

// 1) State
private var videoPrefetchLoopTask: Task<Void, Never>? = nil
private var videoPrefetchContext = VideoPrefetchContext()

private struct VideoPrefetchContext {
    var activeListId: String? = nil
    var adjacentListIds: [String] = []
}

// 2) Public context setter (called from ExploreContentView)
@MainActor
func setVideoPrefetchContext(activeListId: String?, adjacentListIds: [String]) {
    videoPrefetchContext = VideoPrefetchContext(activeListId: activeListId, adjacentListIds: adjacentListIds)
}

// 3) Entry points
@MainActor
func startSustainedVideoPrefetchLoop() {
    videoPrefetchLoopTask?.cancel()
    let snapshot = itemsByListId
    videoPrefetchLoopTask = Task { [weak self] in
        guard let self else { return }
        await self.sustainedVideoPrefetchLoop(itemsByListId: snapshot)
    }
}

@MainActor
func stopSustainedVideoPrefetchLoop() { videoPrefetchLoopTask?.cancel(); videoPrefetchLoopTask = nil }

// 4) The loop — ramps budgets per context using diagonal order
private nonisolated func sustainedVideoPrefetchLoop(itemsByListId: [String: [ExploreMediaItemDoc]]) async {
    // Ramp targets starting points (bytes)
    var activeTarget = 2_097_152      // 2 MB
    var adjacentTarget = 1_048_576    // 1 MB
    let otherTarget = 524_288         // 0.5 MB (static head)

    // Ramp steps and caps (tune as needed)
    let activeStep = 2_097_152        // +2 MB per pass
    let adjacentStep = 1_048_576      // +1 MB per pass
    let activeCap = 32_000_000        // ~32 MB
    let adjacentCap = 8_000_000       // ~8 MB

    while !Task.isCancelled {
        // Snapshot lists and context on MainActor
        let (listsOrder, context) = await MainActor.run { (self.lists.map { $0.id }, self.videoPrefetchContext) }
        if listsOrder.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000); continue }

        // Build diagonal video batches
        let (_, videoBatches) = await MainActor.run { self.computeWeightedDiagonalBatches(itemsByListId: itemsByListId, k: self.yPriorityK, batchSize: self.prefetchBatchSize) }
        let videos: [URL] = videoBatches.flatMap { $0 }
        if videos.isEmpty { try? await Task.sleep(nanoseconds: 500_000_000); continue }

        // Partition by context
        let activeSet: Set<String> = {
            guard let lid = context.activeListId, let items = itemsByListId[lid] else { return [] }
            return Set(items.compactMap { $0.videoUrl })
        }()
        let adjacentSet: Set<String> = {
            var acc = Set<String>()
            for lid in context.adjacentListIds { acc.formUnion((itemsByListId[lid] ?? []).compactMap { $0.videoUrl }) }
            return acc
        }()

        // Iterate in diagonal order so work is well distributed
        for url in videos {
            if Task.isCancelled { return }
            let s = url.absoluteString
            let isActive = activeSet.contains(s)
            let isAdjacent = adjacentSet.contains(s)

            if isActive {
                await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: activeTarget, priority: 0.6)
            } else if isAdjacent {
                await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: adjacentTarget, priority: 0.3)
            } else {
                await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: otherTarget, priority: 0.2)
            }
        }

        // Ramp targets for next pass
        activeTarget = min(activeCap, activeTarget + activeStep)
        adjacentTarget = min(adjacentCap, adjacentTarget + adjacentStep)

        // Small pause between passes to avoid contention with images
        try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s
    }
}
```

Integration point:
- Start the loop automatically when Explore data is applied:

```swift
// In startCacheFirst(), after applying cache/server data and scheduling initial prefetch
await MainActor.run {
    self.startSustainedVideoPrefetchLoop()
}
```

#### B) ExploreContentView — keep context current
Update the sustained loop whenever the user switches lists so the active grid ramps faster and adjacent grids get a smaller budget.

```swift
// ExploreContentView.swift additions/changes

// 1) Helper that already exists in the file (use as-is)
private var adjacentListIDs: [String] { /* existing implementation */ }

// 2) Keep the service context updated
.task {
    if let current = selectedListId {
        await MainActor.run { explore.setVideoPrefetchContext(activeListId: current, adjacentListIds: adjacentListIDs) }
    }
}
.onChange(of: selectedListId) { _, newValue in
    // existing priority batch:
    Task {
        /* existing setPriorities batch code */
    }
    // new: inform ExploreService sustained loop
    Task { await MainActor.run { explore.setVideoPrefetchContext(activeListId: newValue, adjacentListIds: adjacentListIDs) } }
}
```

Keep the existing cell‑level appear/disappear pins and prefetch — they provide immediate responsiveness for visible cells and seed progress overlay (these remain unchanged).

#### C) Optional — per‑URL progressive targets (finer control)
If you prefer strict per‑URL increments instead of group ramps, you can step each URL using its current cached status:

```swift
private func progressivelyPrefetch(_ url: URL, stepBytes: Int, hardCapBytes: Int?, priority: Float) async {
    let snap = await VideoDownloadManager.shared.cachedStatus(for: url)
    let current = Int(snap.downloadedBytes)
    let total = snap.expectedBytes.flatMap(Int.init) ?? hardCapBytes
    let nextTarget = min(current + stepBytes, total ?? (current + stepBytes))
    await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: nextTarget, priority: priority)
}
```

Use this inside the loop instead of group targets for more even progression across URLs.

#### D) Optional — GSPlayer convenience API
Not required for the above design, but if you control the SPM, you can add a convenience to prefetch to end:

```swift
// In VideoDownloadManager (GSPlayer)
public func prefetchToEnd(urls: [URL], priority: Float) {
    for url in urls {
        Task {
            await setPriority(for: url, priority: priority)
            do {
                let handler = try VideoCacheHandler(url: url)
                let downloaded = handler.configuration.downloadedByteCount
                let downloader = VideoDownloader(url: url, cacheHandler: handler)
                downloader.downloadToEnd(from: downloaded)
                await retainPrefetcher(downloader, for: url)
            } catch { /* ignore */ }
        }
    }
}
```

Then call `prefetchToEnd` for active grid (use with care; might be aggressive).

### 9) Tuning parameters
- **Budgets and steps**: Start smaller on cellular; ramp faster on Wi‑Fi.
- **Loop cadence**: 800–1500 ms per pass works well without starving images.
- **Concurrency**: Already configured via `VideoDownloadManager.shared.setConcurrency(maxActive: 6, perHost: 3)` in `ViralGenApp.configureGSPlayer()`.

### 10) Success criteria
- Visible grid videos progress immediately (cell overlay updates) without opening detail.
- Active grid continues downloading across items; adjacent grids progress slowly; others hold a small head.
- Switching tabs rebalances bandwidth within a second.
- After dwelling on a grid, items reach multi‑MB cached state or full cache (per caps).

### 11) Test plan
- Scroll active grid with ≥12 videos; confirm overlay increments with no detail view.
- Switch `selectedListId`; verify `setPriorities` log and budgets update; active grid speeds up.
- Let the app idle on a grid for 1–2 minutes; verify cached bytes ramp to caps.
- Try on Wi‑Fi vs cellular and with different `setConcurrency` values.

### 12) Risks & mitigations
- **Network contention with images**: Stagger passes and keep lower priorities for videos when images are active.
- **Over‑aggressive caching**: Cap budgets (`activeCap`, `adjacentCap`) and tune per network type.
- **Unknown content length**: Use progressive targets with a hard cap or group caps; once `expectedBytes` becomes known, the loop naturally stops increasing beyond the length.

### 13) Code snippets index
- `ExploreService.startSustainedVideoPrefetchLoop/stop/setVideoPrefetchContext`.
- `ExploreContentView.onChange(selectedListId)`: call `setVideoPrefetchContext` in addition to existing `setPriorities`.
- Optional `VideoDownloadManager.prefetchToEnd` helper (SPM).

---

This PRD adds the missing sustained scheduler. Preferred: GSPlayer’s `VideoPrefetchController` (SPM) for a reusable, policy‑driven engine; fallback: app‑side loop in `ExploreService`. Both ensure videos continue caching while browsing, ordered by the same diagonal sweep used for images.

