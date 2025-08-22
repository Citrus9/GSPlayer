## PRD: SwiftUI — Resilient playback when GSPlayer reports len=0 on first response

### Context
- A specific video opens to a black screen with `−11829 Cannot Open` while GSPlayer logs show `contentInfo utType=public.mpeg-4 len=0`.
- GSPlayer-side fixes ensure positive `contentLength` going forward, but the app should handle edge cases defensively and improve first-open success.

### Root cause at app layer
- On first open, if the first `contentInfo` arrives with `len=0` (or a stale 0 from cache), the player item can fail quickly and not recover without a retry.
- The app currently pins and sets priority, but does not prewarm the exact head range for the video nor implement a targeted retry policy for `−11829`.

### Goals
- Proactively prewarm the head for the tapped video before presenting detail (or immediately on appear) to ensure bytes are available.
- Implement a short, single retry on `−11829` that also invalidates any stale loader state.
- Add bright logs to correlate retries and warmup.

### High-level approach
1) Prewarm: When a grid cell is tapped (or detail appears), trigger `VideoDownloadManager.prefetch([url], byteCount: 1MB, priority: 0.9)` fire-and-forget.
2) Retry on `−11829`: On error, immediately invalidate loader, wait ~150–250 ms, and reattempt playback once (while pinned). If second attempt fails, surface error.
3) Keep existing pin/unpin, list-priority logic; add minimal new code in `ExploreContentView` and `VideoPlayer`.

### Detailed changes (with code snippets)

#### 1) Prewarm head on tap before presenting detail
File: `ViralGen/VideoGen/Views/Explore/ExploreContentView.swift`

```swift
private func presentDetail() {
    if item.type == .video, let s = item.videoUrl, !s.isEmpty, let url = URL(string: s) {
        // Proactive head prefetch to avoid empty first response
        Task {
            await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: 1_048_576, priority: 0.9)
            print("🎥 [EXP] 📦 prewarm 1MB — detailTap — \(url.lastPathComponent)")
        }
    }
    zoom.presentExploreDetail(item: item, listId: listId, sourceID: zoomID)
}
```

Why: Ensures the first open has usable bytes even if the CDN returns unknown totals initially.

#### 2) Single retry policy for `−11829` with loader invalidation
File: `ViralGen/Utils/VideoPlayer.swift`

```swift
@MainActor
extension VideoPlayer: UIViewRepresentable {
    // ... existing code ...
    func makeUIView(context: Context) -> VideoPlayerView {
        let uiView = VideoPlayerView()
        // ... existing bindings ...
        uiView.stateDidChanged = { [unowned uiView] _ in
            let state: State = uiView.convertState()
            if case .playing = state { context.coordinator.startObserver(uiView: uiView) } else { context.coordinator.stopObserver(uiView: uiView) }
            switch state {
            case .loading:
                print("🎥 [VID] ⏳ loading — \(self.url.lastPathComponent)")
            case .playing(let total):
                print("🎥 [VID] ▶️ playing — dur=\(Int(total))s — \(self.url.lastPathComponent)")
            case .paused(let p, let b):
                print("🎥 [VID] ⏸ paused — p=\(String(format: "%.2f", p)) b=\(String(format: "%.2f", b)) — \(self.url.lastPathComponent)")
            case .error(let e):
                print("🎥 [VID] ❌ error — \(e.code) \(e.localizedDescription) — \(self.url.lastPathComponent)")
                context.coordinator.handlePlaybackError(error: e, url: self.url, uiView: uiView)
            }
            DispatchQueue.main.async { self.config.handler.onStateChanged?(state) }
        }
        return uiView
    }

    class Coordinator: NSObject {
        // ... existing properties ...
        private var hasRetriedOnce: Bool = false

        func handlePlaybackError(error: NSError, url: URL, uiView: VideoPlayerView) {
            guard error.code == -11829 else { return }
            guard hasRetriedOnce == false else { return }
            hasRetriedOnce = true
            Task {
                print("🎥 [VID] 🔁 retry — cannotOpen — invalidating loader and prewarming — \(url.lastPathComponent)")
                // Invalidate stale loader state
                VideoLoadManager.shared.invalidate(url: url)
                // Aggressive head prewarm and keep pinned
                await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0)
                await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: 1_048_576, priority: 1.0)
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms backoff
                uiView.play(for: url)
            }
        }
    }
}
```

Why: A small delay allows metadata to settle and head bytes to land. Invalidating the loader clears any bad `len=0` content info. The single retry avoids loops.

#### 3) Optional: Prewarm on detail appear
File: `ViralGen/VideoGen/Views/Explore/ExploreContentView.swift`

```swift
// In ExploreDetailView.video case .onAppear
.onAppear {
    play = true
    Task {
        await VideoDownloadManager.shared.pin(url: url, scope: "detailPlayback", priority: 1.0)
        // Ensure head is present right away
        await VideoDownloadManager.shared.prefetch(urls: [url], byteCount: 1_048_576, priority: 1.0)
    }
    print("🎥 [GS] 🎯 pin 1.0 + prewarm — detailPlayback — \(url.lastPathComponent)")
}
```

### Risks and mitigations
- Extra prewarm may increase bandwidth slightly on first-open.
  - Mitigation: 1 MB is modest; maintain pin-based scheduling to prioritize visible content.
- Retry could mask other errors if misused.
  - Mitigation: Retry only once and only for `−11829`.

### Acceptance criteria
- Tapping the previously failing video reliably starts playback; no black screen.
- Logs show prewarm on tap/appear and (if needed) a single retry with loader invalidation.
- No repeated retries; subsequent opens do not produce `−11829`.

### Testing checklist
1) Tap the previously failing video: expect prewarm log before presentation; video plays.
2) Force a failure (network toggle) to trigger `−11829`: app performs one retry after invalidation; playback then succeeds or fails gracefully.
3) Open/dismiss/reopen rapidly: no black screens; loader invalidation on disappear still applied.


