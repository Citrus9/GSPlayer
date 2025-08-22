//
//  VideoDownloadManager.swift
//  GSPlayer
//
//  Created by GSPlayer PRD.
//

import Foundation

@available(iOS 13.0, macOS 10.15, *)
public struct DownloadProgress: Sendable {
    public let url: URL
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public let priority: Float
}

@available(iOS 13.0, macOS 10.15, *)
public actor VideoDownloadManager {
    public static let shared = VideoDownloadManager()

    // MARK: - Scheduling State (minimal implementation)
    struct Entry { var priority: Float; var pins: [String: Float] }
    private var entries: [URL: Entry] = [:]

    private var maxActive = 3
    private var perHost = 2

    // MARK: - Progress Streams
    private var progressContinuations: [URL: [AsyncStream<DownloadProgress>.Continuation]] = [:]

    public func setPriority(for url: URL, priority: Float) {
        ensure(url)
        entries[url]!.priority = priority
    }

    public func pin(url: URL, scope: String, priority: Float) {
        ensure(url)
        entries[url]!.pins[scope] = priority
    }

    public func unpin(url: URL, scope: String) {
        entries[url]?.pins.removeValue(forKey: scope)
    }

    public func pause(url: URL) {
        // Placeholder: hook into task suspension in a fuller implementation
    }

    public func resume(url: URL) {
        // Placeholder: hook into task resumption in a fuller implementation
    }

    public func setConcurrency(maxActive: Int, perHost: Int) {
        self.maxActive = maxActive
        self.perHost = perHost
        _ = (maxActive, perHost) // silence unused warnings for now
    }

    public func isDownloading(url: URL) -> Bool {
        // Minimal stub. A full implementation would track active tasks.
        return false
    }

    public func prefetch(urls: [URL], byteCount: Int, priority: Float) {
        // Minimal implementation: fire-and-forget small prefetches using existing downloader
        for url in urls {
            if #available(iOS 13.0, macOS 10.15, *) {
                Task.detached { [priority] in
                    await VideoDownloadManager.shared.setPriority(for: url, priority: priority)
                    do {
                        let cacheHandler = try VideoCacheHandler(url: url)
                        if cacheHandler.configuration.downloadedByteCount < byteCount {
                            let downloader = VideoDownloader(url: url, cacheHandler: cacheHandler)
                            downloader.download(from: 0, length: byteCount)
                        }
                    } catch {
                        // Ignore prefetch errors in minimal implementation
                    }
                }
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
}


