//
//  VideoDownloadManager.swift
//  GSPlayer
//
//  Created by GSPlayer PRD.
//

import Foundation

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
    
    // URL ↔︎ Task mapping
    private var urlToTaskIds: [URL: Set<Int>] = [:]
    private var taskIdToURL: [Int: URL] = [:]

    private var maxActive = 3
    private var perHost = 2

    // MARK: - Progress Streams
    private var progressContinuations: [URL: [AsyncStream<DownloadProgress>.Continuation]] = [:]

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

    public func pause(url: URL) {
        guard let tids = urlToTaskIds[url] else { return }
        let tasks = session.getAllTasksSync()
        for tid in tids {
            if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                task.suspend()
            }
        }
    }
    
    public func resume(url: URL) {
        guard let tids = urlToTaskIds[url] else { return }
        let tasks = session.getAllTasksSync()
        for tid in tids {
            if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                task.resume()
            }
        }
    }

    public func setConcurrency(maxActive: Int, perHost: Int) {
        self.maxActive = maxActive
        self.perHost = perHost
        _ = (maxActive, perHost) // silence unused warnings for now
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
        }
    }

    public func currentPriority(for url: URL) -> Float {
        guard let entry = entries[url] else { return 0 }
        return max(entry.priority, entry.pins.values.max() ?? 0)
    }

    // Called by internal components to publish progress
    public func publish(_ progress: DownloadProgress) {
        guard let continuations = progressContinuations[progress.url] else { return }
        for c in continuations { c.yield(progress) }
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
            if urlToTaskIds[url]?.isEmpty == true { urlToTaskIds.removeValue(forKey: url) }
        }
    }

    // Apply new effective priority to all active tasks for URL
    private func applyPriority(to url: URL) {
        guard let tids = urlToTaskIds[url] else { return }
        let eff = currentPriority(for: url)
        let tasks = session.getAllTasksSync()
        for tid in tids {
            if let task = tasks.first(where: { $0.taskIdentifier == tid }) {
                task.priority = eff
            }
        }
    }
}

// Helper to synchronously snapshot tasks inside actor
private extension URLSession {
    func getAllTasksSync() -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []
        let sem = DispatchSemaphore(value: 0)
        getAllTasks { arr in tasks = arr; sem.signal() }
        sem.wait()
        return tasks
    }
}


