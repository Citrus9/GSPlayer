//
//  VideoDownloadManager.swift
//  GSPlayer
//
//  Created by GSPlayer PRD.
//

import Foundation

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

public struct DownloadProgress: Sendable {
    public let url: URL
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let priority: Float
}

public actor VideoDownloadManager {
    public static let shared = VideoDownloadManager()

    // MARK: - URLSession (shared)
    private lazy var delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "GSPlayer.URLSession.delegate"
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let sessionDelegate = VideoDownloaderSessionDelegateHandler()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: delegateQueue)
    }()

    public var customAuthChallengeHandler: ((URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))? {
        didSet {
            let handler = customAuthChallengeHandler
            sessionDelegate.authChallengeHandler = { challenge, completion in
                if let handler = handler {
                    let result = handler(challenge)
                    completion(result.0, result.1)
                } else {
                    completion(.performDefaultHandling, nil)
                }
            }
        }
    }

    public func sharedSession() -> URLSession { session }
    func register(task: URLSessionTask, delegate: VideoDownloaderSessionDelegateHandlerDelegate) {
        sessionDelegate.register(task: task, delegate: delegate)
    }

    // MARK: - Scheduling State
    struct Entry { var priority: Float; var pins: [String: Float] }
    private var entries: [URL: Entry] = [:]
    private var prefetchers: [URL: VideoDownloader] = [:]
    
    // URL ↔︎ Task mapping
    private var urlToTaskIds: [URL: Set<Int>] = [:]
    private var taskIdToURL: [Int: URL] = [:]

    private var maxActive = 3
    private var perHost = 2

    // MARK: - Progress Streams
    private var progressContinuations: [URL: [AsyncStream<DownloadProgress>.Continuation]] = [:]

    public func setPriority(for url: URL, priority: Float) async {
        ensure(url)
        entries[url]!.priority = priority
        await self.applyPriority(to: url)
    }

    public func pin(url: URL, scope: String, priority: Float) async {
        ensure(url)
        entries[url]!.pins[scope] = priority
        await self.applyPriority(to: url)
    }

    public func unpin(url: URL, scope: String) async {
        entries[url]?.pins.removeValue(forKey: scope)
        await self.applyPriority(to: url)
    }

    public func pause(url: URL) async {
        await self.pauseImpl(url: url)
    }
    
    public func resume(url: URL) async {
        await self.resumeImpl(url: url)
    }

    public func setConcurrency(maxActive: Int, perHost: Int) {
        self.maxActive = maxActive
        self.perHost = perHost
        Task { await recreateSessionIfIdle() }
    }

    public func isDownloading(url: URL) -> Bool {
        return (urlToTaskIds[url]?.isEmpty == false)
    }

    public func prefetch(urls: [URL], byteCount: Int, priority: Float) {
        for url in urls {
            Task { [priority] in
                if await VideoDownloadManager.shared.isDownloading(url: url) {
                    return
                }
                if let cfg = try? VideoCacheManager.cachedConfiguration(for: url),
                   cfg.downloadedByteCount >= byteCount {
                    return
                }
                await VideoDownloadManager.shared.setPriority(for: url, priority: priority)
                do {
                    let cacheHandler = try VideoCacheHandler(url: url)
                    if cacheHandler.configuration.downloadedByteCount < byteCount {
                        let downloader = VideoDownloader(url: url, cacheHandler: cacheHandler)
                        await retainPrefetcher(downloader, for: url)
                        downloader.download(from: 0, length: byteCount)
                    }
                } catch { }
            }
        }
    }

    public func progressStream(for url: URL) -> AsyncStream<DownloadProgress> {
        return AsyncStream<DownloadProgress> { continuation in
            if progressContinuations[url] == nil { progressContinuations[url] = [] }
            progressContinuations[url]?.append(continuation)

            // Emit initial snapshot from on-disk cache so UI renders instantly.
            let cfg = try? VideoCacheManager.cachedConfiguration(for: url)
            let received = Int64(cfg?.downloadedByteCount ?? 0)
            let exp = Int64(cfg?.info?.contentLength ?? 0)
            let expected = exp > 0 ? exp : nil
            let pr = currentPriority(for: url)
            continuation.yield(DownloadProgress(url: url, receivedBytes: received, expectedBytes: expected, priority: pr))
        }
    }

    public func currentPriority(for url: URL) -> Float {
        guard let entry = entries[url] else { return 0 }
        return max(entry.priority, entry.pins.values.max() ?? 0)
    }

    // Batch update priorities with a single task scan
    public func setPriorities(_ changes: [(URL, Float)]) async {
        for (url, p) in changes {
            ensure(url)
            entries[url]!.priority = p
        }
        let tasks = await session.getAllTasksAsync()
        for (url, _) in changes {
            guard let tids = urlToTaskIds[url] else { continue }
            let eff = currentPriority(for: url)
            for tid in tids {
                if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                    task.priority = eff
                }
            }
        }
    }

    // Called by internal components to publish progress
    public func publish(_ progress: DownloadProgress) {
        guard let continuations = progressContinuations[progress.url] else { return }
        for c in continuations { c.yield(progress) }
    }

    // MARK: - Cached Status
    public func cachedStatus(for url: URL) -> CachedStatus {
        let cfg = (try? VideoCacheManager.cachedConfiguration(for: url))
        let downloaded = Int64(cfg?.downloadedByteCount ?? 0)
        let exp = Int64(cfg?.info?.contentLength ?? 0)
        let expected: Int64? = exp > 0 ? exp : nil
        #if DEBUG
        print("🎥 [GS] 🧮 cachedStatus — recv=\(downloaded) exp=\(expected ?? -1) — \(url.lastPathComponent)")
        #endif
        return CachedStatus(url: url, downloadedBytes: downloaded, expectedBytes: expected)
    }

    private func ensure(_ url: URL) {
        if entries[url] == nil { entries[url] = Entry(priority: 0.2, pins: [:]) }
    }

    // MARK: - URL ↔︎ Task registry API
    public func track(task: URLSessionTask, for url: URL) {
        let tid = task.taskIdentifier
        if urlToTaskIds[url] == nil { urlToTaskIds[url] = [] }
        urlToTaskIds[url]?.insert(tid)
        taskIdToURL[tid] = url
    }

    public func untrack(taskIdentifier: Int) {
        if let url = taskIdToURL.removeValue(forKey: taskIdentifier) {
            urlToTaskIds[url]?.remove(taskIdentifier)
            if urlToTaskIds[url]?.isEmpty == true {
                urlToTaskIds.removeValue(forKey: url)
                prefetchers.removeValue(forKey: url)
            }
        }
    }

    // Apply new effective priority to all active tasks for URL
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

    private func retainPrefetcher(_ downloader: VideoDownloader, for url: URL) async {
        prefetchers[url] = downloader
    }

    private func recreateSessionIfIdle() async {
        let tasks = await session.getAllTasksAsync()
        guard tasks.isEmpty else { return }
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = perHost
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg, delegate: sessionDelegate, delegateQueue: delegateQueue)
    }
}

// Async helper to snapshot tasks without blocking
@available(iOS 13.0, macOS 10.15, *)
private extension URLSession {
    func getAllTasksAsync() async -> [URLSessionTask] {
        await withCheckedContinuation { cont in
            getAllTasks { tasks in cont.resume(returning: tasks) }
        }
    }
}

// MARK: - Async implementations for pause/resume
private extension VideoDownloadManager {
    func pauseImpl(url: URL) async {
        guard let tids = urlToTaskIds[url] else { return }
        let tasks = await session.getAllTasksAsync()
        for tid in tids {
            if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                task.suspend()
            }
        }
    }

    func resumeImpl(url: URL) async {
        guard let tids = urlToTaskIds[url] else { return }
        let tasks = await session.getAllTasksAsync()
        for tid in tids {
            if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                task.resume()
            }
        }
    }
}


