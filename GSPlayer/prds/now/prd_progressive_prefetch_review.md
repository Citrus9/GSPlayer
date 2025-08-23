### Progressive Prefetch, GSPlayer Integration, and Grid Pipeline Review

Date: 2025-08-22
Owner: ViralGen iOS

---

## TL;DR (Executive Summary)

- The overall prefetch architecture (weighted-diagonal batching for images + sustained progressive prefetch for videos, GSPlayer-backed) is solid and close to production-ready.
- There are a few P0/P1 fixes to make it robust under scale and avoid 416 range errors and leaks:
  - P0: Fix clamp in `progressivelyPrefetch` to honor both known expected size and hard caps (prevent 416 Invalid Range). [Client]
  - P0: Avoid stale data in sustained prefetch loop by reading `self.itemsByListId` on each pass (not a startup snapshot only). [Client]
  - P0: Add termination cleanup in GSPlayer `progressStream` to prevent continuation leaks when views disappear. [GSPlayer]
  - P1: Introduce a per-pass budget and fairness in the sustained loop to limit churn when grids are large. [Client]
  - P1: Add richer observability (OSLog signposts; per-URL counters) and guardrails (network/battery awareness, cache capacity watermarks). [Client; GSPlayer optional]

---

### If you're new to this, read this first

- Prefetch means “download a bit before the user needs it” so scrolling feels instant and video starts fast.
- We don’t download the whole video up front (too heavy). We fetch small chunks (like 0.5–2 MB) step by step.
- We give higher priority to what the user can see now, medium to the next/adjacent lists, and low to everything else.
- We must never ask the server for bytes past the real end of the file, or the server can reply 416 (invalid range). That’s noisy and wastes time.

## Current Implementation Overview

- ExploreService
  - Weighted anti-diagonal batching via `computeWeightedDiagonalBatches(k, batchSize)` to interleave columns (lists) and rows (items) with tuneable Y priority and fixed batch sizes for images/videos.
  - Coalesced background prefetch via `schedulePrefetch` → `prefetchMedia` (images and videos concurrently so videos are not serialized behind images).
  - Sustained video prefetch loop that progressively increases per-URL byte targets with small steps and hard caps based on context (active list, adjacent lists, others).
  - Per-URL progressive stepper:

```328:346:ViralGen/Services/Explore/ExploreService.swift
private nonisolated func progressivelyPrefetch(
    _ url: URL,
    stepBytes: Int,
    hardCapBytes: Int?,
    priority: Float
) async {
    let snap = await VideoDownloadManager.shared.cachedStatus(for: url)
    let current = Int(snap.downloadedBytes)
    let expected: Int? = snap.expectedBytes.map { Int($0) }
    // Skip if already fully downloaded (when expected is known)
    if let exp = expected, current >= exp { return }

    // Determine next target, clamped to known expected bytes or optional hard cap
    let cap: Int? = hardCapBytes ?? expected
    let nextTarget = min(cap ?? (current + stepBytes), current + stepBytes)
    if nextTarget <= current { return }

    await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: nextTarget, priority: priority)
}
```

- ExploreContentView
  - Per-cell pin/unpin of GSPlayer priorities on visibility; head prewarm on tap; streaming of progress into small overlays; list-change batch priority updates using `setPriorities`.
  - Aggressive but bounded image prefetch around visible cells, with provider-level cache filtering.

- VideoPlayer (GSPlayer-backed)
  - During playback, raises priority; handles -11829 cannot open by invalidating loader and prewarming 1MB, then retries.

- GSPlayer custom fork (in-project `PRD/projectStructure/GSPlayer.md`)
  - Actor-based `VideoDownloadManager` with task tracking, priority pinning, and `AsyncStream` progress publication.
  - `VideoCacheHandler` + `CacheIO` actor wrapper for debounced saves; robust Content-Range parsing and info population on first 206.

---

### Plain-English summary of the design

- For images: we prefetch in small, ordered batches so the grid doesn’t stutter when you scroll.
- For videos: we slowly “grow” how many bytes we have per video URL based on where the user is looking.
- Priorities: visible cells get the most attention, adjacent lists get some, far-away content gets a little.
- Everything runs in the background and tries not to fight the main thread.

## Deep Findings

### 1) Progressive prefetch clamp can overshoot expected length (P0)

- The current clamp logic prefers `hardCapBytes` over `expected` when both are present:
  - `let cap: Int? = hardCapBytes ?? expected`
  - This means if the server-provided `expected` is smaller than `hardCapBytes`, requests can be planned beyond the real end, increasing chances of 416 on strict CDNs.
- Recommended: clamp to the minimum of both when available, and otherwise clamp to whichever is known.
  - Intended logic: `cap = min(expected, hardCapBytes)` ignoring `nil`s.
  - With this, `nextTarget = min(current + stepBytes, cap)` if `cap` exists, else just `current + stepBytes`.
- Side note: Even if 416 occurs, the forked GSPlayer recovers, but we should prevent sending out-of-range requests at the source.

In plain English:
- Imagine you have a 10‑page PDF but your “max allowed” is set to 20. If you try to read page 15, you’ll get an error because the book ends at 10.
- We should always respect the smaller limit: the real book length (expected) versus our personal max (hard cap).

What to do:
- When both values are known, pick the smaller one. Then don’t request beyond that.

### 2) Sustained loop uses a snapshot of `itemsByListId` (P0)

- `startSustainedVideoPrefetchLoop()` captures a snapshot of `itemsByListId` and passes it to the nonisolated loop. If lists/items update post-start, the loop won’t see changes until it is restarted.
- Recommended: on each loop pass, read `self.itemsByListId` on MainActor before computing batches. This keeps the loop aligned with dynamic content.

In plain English:
- The loop took a photo at app start and keeps staring at it. But the grid can change (new data, resorting). The loop should look at the live screen every time it runs.

What to do:
- Inside the while-loop, fetch the current lists and items from the MainActor each pass before planning work.

### 3) Progress stream continuation cleanup (P0)

- `VideoDownloadManager.progressStream(for:)` appends an `AsyncStream` continuation but does not remove it when the stream consumer is cancelled (e.g., a cell disappears). This can leak continuations, slowly inflating memory.
- Recommended: keep an identifier for each continuation and install an `onTermination` handler to remove it from `progressContinuations[url]`.

In plain English:
- When a cell scrolls off-screen, we should stop sending it updates. Otherwise, we keep a dangling wire around and memory slowly grows.

What to do:
- When creating the AsyncStream, store a token and remove it in `onTermination`.

### 4) Per-pass fairness and budgets (P1)

- The sustained loop iterates all videos derived from batched ordering and issues a prefetch step per URL every pass. On large grids this can cause frequent state churn (many actor calls and eligibility checks) even when little work is needed.
- Recommended:
  - Add per-pass URL budget (e.g., process first N candidates per pass) with rotation between passes for fairness.
  - Backoff when a high proportion of URLs are already at cap/complete to reduce overhead.
  - Consider scaling `stepBytes` down under constrained conditions (see 6).

In plain English:
- Don’t try to help everybody every millisecond. Help a fixed number, then rotate. If most items are already done, nap a bit longer between rounds.

What to do:
- Add a “max URLs per pass” and a moving start index. Measure advancement; if little changed, increase sleep a bit.

### 5) `isDownloading(url)` gating and step growth (FYI)

- The current GSPlayer `prefetch(urls:byteCount:priority:)` skips if a URL is already downloading. This means progressive increases to the target length only occur between downloads. That is acceptable; it avoids resizing in-flight tasks and keeps the mental model simple.
- If we later want smoother continuous growth, we could add a `prefetchTo(byteCount:)` that updates planned actions for the in-flight downloader. Not necessary for v1.

In plain English:
- If something is already being downloaded, don’t poke it constantly to change size. Let it finish; then we plan the next step. That’s fine for v1.

### 6) Guardrails and adaptivity (P1) (don't do it now)

- Add adaptivity for:
  - Low Power Mode (reduce `maxActive`, `stepBytes`, and/or pause adjacent prefetch).
  - Network path (WWAN vs Wi‑Fi; consider `NWPathMonitor` to reduce aggression on cellular).
  - Disk watermarks (query cache size and throttle/pause below reserve free space).
- You already check free capacity opportunistically in `VideoCacheHandler.cache`; surface this via telemetry and optionally a policy hook to pause prefetch while disk is tight.

In plain English:
- Be nicer on battery and cellular. Slow down or pause when the phone is in Low Power Mode or on mobile data. Also don’t fill the last bits of disk space.

What to do:
- Check Low Power Mode and network type; reduce step sizes and concurrency. Use a disk watermark to pause prefetching when space is tight.

### 7) Observability and visibility (P1)

- Add OSLog signposts for prefetch cycles, including:
  - Batch counts, URL counts, bytes targeted, time-to-first-byte, completion/416 counts.
  - Per-URL priority changes and pin scopes.
- Surface a small developer overlay toggle in the Explore grid (e.g., percent cached, current priority, step size) — you already display progress/priority in the cell, which is great. Add one aggregate row for the page.

In plain English:
- Add logs and a simple debug view so we can see what the system is doing without guessing.

What to do:
- Add OSLog signposts for batches, and a small toggleable overlay that shows totals for the page (how many videos warming, average % cached, etc.).

---

## Targeted Code Changes (Recommended)

### A) Fix clamp in `progressivelyPrefetch` (P0)

Proposed logic:

```swift
// Use the minimum of known expected size and hard cap if both exist
let cap = [expected, hardCapBytes].compactMap { $0 }.min()
let target = current + stepBytes
let nextTarget = cap.map { min(target, $0) } ?? target
if nextTarget <= current { return }
await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: nextTarget, priority: priority)
```

Step-by-step (for juniors):
1) Open `ExploreService.progressivelyPrefetch`.
2) Replace the clamp lines with the snippet above.
3) Build and run. Scroll a grid with videos and confirm you don’t see 416 errors in logs.

### B) Read live `itemsByListId` in sustained loop (P0)

- Inside `sustainedVideoPrefetchLoop`, fetch `self.itemsByListId` and `self.lists` on each iteration via `await MainActor.run { ... }` before computing batches.

Step-by-step (for juniors):
1) Inside the `while !Task.isCancelled` loop, before computing batches, call `await MainActor.run { (self.lists.map { $0.id }, self.itemsByListId) }`.
2) Use those live values to compute batches.
3) Test by changing lists (or toggling stress test) and ensuring the loop reacts without needing a restart.

### C) Clean up `progressStream` continuations (P0) [GSPlayer]

- Add `onTermination` to remove the continuation for that URL. Optionally expose `func stopProgress(for:)` to proactively clear.

Step-by-step (for juniors):
1) In `VideoDownloadManager.progressStream(for:)`, keep a unique ID for the continuation you append.
2) Call `continuation.onTermination = { _ in /* remove by ID from the array */ }`.
3) Verify memory doesn’t grow when you scroll a lot.

### D) Add per-pass URL budget and backoff (P1) [Client]

- Example: process only first 60–100 URLs per pass, then sleep; rotate start index between passes for fairness.
- Backoff: if fewer than X% of candidates advanced (already at cap or complete), increment sleep up to a ceiling.

Step-by-step (for juniors):
1) Add `let maxPerPass = 80` (tune later).
2) Iterate over only `videos.prefix(maxPerPass)` (but rotate the starting index each pass).
3) Track how many `progressivelyPrefetch` calls actually advanced; if < 10%, `sleep` a bit longer next pass.

### E) Adaptive policy hooks (P1) [Client] (Don't do it for now)

- Provide an injectable `PrefetchPolicy` that reads `ProcessInfo.isLowPowerModeEnabled`, `NWPathMonitor`, and disk watermarks to adjust `stepBytes`, caps, and concurrency at runtime.

Step-by-step (for juniors):
1) Create a `PrefetchPolicy` struct with the knobs you need (steps, caps, budgets).
2) Fill it from environment state (Low Power, network, disk).
3) Use it in `sustainedVideoPrefetchLoop` and `startHeadPrefetchForTopVideos` to decide sizes and priorities.

---

## Production Readiness Checklist

- P0 fixes implemented: clamp, live items, stream cleanup.
- No 416s in sustained prefetch under test CDN.
- Memory steady with repeated scrolling (no growth from leaked continuations).
- Prefetch does not regress UI responsiveness: images and videos proceed concurrently; per-pass budgets prevent main-thread contention.
- OSLog counters in place to track:
  - Started downloads, completed, errors (esp. 416)
  - Average prefetch step time, bytes written
  - Disk watermark pauses
- Tests:
  - Unit tests for `computeWeightedDiagonalBatches` ordering under varying `k` and small grids.
  - Integration test with mock server that enforces strict range validation to verify no overshoot.

Beginner test guide:
- Scroll the Explore grid for 2–3 minutes; watch memory in Xcode. It should stay steady.
- Toggle Airplane Mode or switch to cellular to see that prefetch slows down (after adaptivity).
- Fill device storage close to full; verify prefetch pauses rather than crashing.

---

## Parameter Guidance (initial)

- `yPriorityK`: 1.2–1.6 for two-column grid; nudge toward row depth without starving columns.
- `prefetchBatchSize`: 24–36 per batch; consider device-size-based tuning.
- Sustained steps/caps:
  - Active: step 2 MB, cap 32 MB
  - Adjacent: step 1 MB, cap 8 MB
  - Others: step 0.5 MB, cap 4 MB
  - Reduce steps by 50% on WWAN or Low Power Mode.

---

## Notes on GSPlayer Fork Robustness

- Content-Range parsing and info initialization look good; fallback to `1` avoids zero-length issues with AVFoundation.
- `VideoCacheHandler` uses synchronized file handles for read/write and debounced saves through the `CacheIO` actor — good for concurrency.
- Task registry in `VideoDownloadManager` cleanly tracks URL ↔︎ task; priorities are applied across all active tasks for a URL.
- Buffering in `VideoDownloaderSessionDelegateHandler` reduces delegate churn; consider exposing a metric for buffer flush sizes.

---

## Appendix: Why the clamp matters (416 prevention)

- Without `min(expected, hardCap)`, if the server returns a small `Content-Length` and our `hardCap` is larger, the stepper may plan ranges that extend beyond the end. Strict servers reply with 416 to those chunk requests.
- While the GSPlayer requestor often recovers once `VideoInfo` is set, avoiding out-of-range requests reduces error logs, retries, and time-to-warm.

---

## Glossary (for juniors)

- Prefetch: Download some data before it’s needed so UI feels instant.
- Step bytes: How much extra we try to download for a video in each loop pass.
- Cap: Upper limit to how much we’ll prefetch for a video.
- Expected bytes: The real size of the file, as told by the server.
- 416: HTTP error “Requested Range Not Satisfiable” — you asked past the end of the file.
- Priority/pin: A way to tell the downloader what’s important now (visible grid cells > adjacent > others).



