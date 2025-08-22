//
//  VideoDownloaderHandler.swift
//  GSPlayer
//
//  Created by Gesen on 2019/4/20.
//  Copyright © 2019 Gesen. All rights reserved.
//

import Foundation

extension Notification.Name {
    
    public static let VideoDownloadProgressDidChanged = Notification.Name(rawValue: "me.gesen.player.downloader.progress.changed")
    
    public static let VideoDownloadDidFinished = Notification.Name("me.gesen.player.downloader.finished")
    
}

private let delegateQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 2
    return queue
}()

protocol VideoDownloaderHandlerDelegate: AnyObject {
    
    func handler(_ handler: VideoDownloaderHandler, didReceive response: URLResponse)
    func handler(_ handler: VideoDownloaderHandler, didReceive data: Data, isLocal: Bool)
    func handler(_ handler: VideoDownloaderHandler, didFinish error: Error?)
    
}

class VideoDownloaderHandler {
    
    weak var delegate: VideoDownloaderHandlerDelegate?
    
    private let url: URL
    private var actions: [VideoCacheAction]
    private let cacheHandler: VideoCacheHandler
    private let cacheIO: CacheIO
    
    private var task: URLSessionDataTask?
    
    private var isCancelled = false
    private var startOffset = 0
    private var lastNotifyTime: TimeInterval = 0
    
    init(url: URL, actions: [VideoCacheAction], cacheHandler: VideoCacheHandler) {
        self.url = url
        self.actions = actions
        self.cacheHandler = cacheHandler
        self.cacheIO = CacheIO(handler: cacheHandler)
    }
    
    deinit {
        cancel()
    }
    
    func start() {
        processActions()
    }
    
    func cancel() {
        task?.cancel()
        isCancelled = true
    }
    
    func resume() {
        task?.resume()
    }
    
    func suspend() {
        task?.suspend()
    }
    
}

extension VideoDownloaderHandler: VideoDownloaderSessionDelegateHandlerDelegate {
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        #if !os(macOS)
        if let http = response as? HTTPURLResponse {
            let code = http.statusCode
            #if DEBUG
            let cr = http.value(forHeaderKey: "Content-Range") ?? "-"
            print("🎥 [GS] 🛰️ response ok — status=\(code) mime=\(response.mimeType ?? "") cr=\(cr)")
            #endif
            if (200..<300).contains(code) || code == 206 {
                delegate?.handler(self, didReceive: response)
                completionHandler(.allow)
            } else {
                #if DEBUG
                print("🎥 [GS] 🚫 response rejected — status=\(code)")
                #endif
                completionHandler(.cancel)
            }
            return
        }
        #endif
        delegate?.handler(self, didReceive: response)
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isCancelled else { return }
        
        let range = NSRange(location: startOffset, length: data.count)
        Task { [cacheIO] in
            _ = await cacheIO.cache(data: data, for: range)
            await cacheIO.saveDebounced()
        }
        startOffset += data.count
        delegate?.handler(self, didReceive: data, isLocal: false)
        notifyProgress(flush: false)
        
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { [cacheIO] in
            await cacheIO.saveNow()
        }
        
        if let error = error {
            delegate?.handler(self, didFinish: error)
            notifyFinished(error: error)
        } else {
            notifyProgress(flush: true)
            notifyFinished(error: nil)
            processActions()
        }
    }
    
}

private extension VideoDownloaderHandler {
    
    func processActions() {
        guard !isCancelled else { return }
        guard let action = actions.first else {
            delegate?.handler(self, didFinish: nil)
            return
        }
        
        actions.removeFirst()
        
        guard action.actionType == .remote else {
            let data = cacheHandler.cachedData(for: action.range)
            delegate?.handler(self, didReceive: data, isLocal: true)
            processActions()
            return
        }
        
        var urlRequest = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        
        let start = action.range.location
        let end = action.range.location + action.range.length - 1
        urlRequest.addValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        
        for field in VideoLoadManager.shared.customHTTPHeaderFields?(url) ?? [:] {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.key)
        }
        
        startOffset = start
        
        Task { [weak self] in
            guard let self else { return }
            let session = await VideoDownloadManager.shared.sharedSession()
            let t = session.dataTask(with: urlRequest)
            self.task = t
            await VideoDownloadManager.shared.register(task: t, delegate: self)
            await VideoDownloadManager.shared.track(task: t, for: self.url)
            let effPriority = await VideoDownloadManager.shared.currentPriority(for: self.url)
            t.priority = effPriority
            t.resume()
        }
    }
    
    func notifyProgress(flush: Bool) {
        let currentTime = CFAbsoluteTimeGetCurrent()
        guard lastNotifyTime < currentTime - 0.1 || flush else { return }
        lastNotifyTime = currentTime
        
        let configuration = cacheHandler.configuration
        NotificationCenter.default.post(
            name: .VideoDownloadProgressDidChanged,
            object: nil,
            userInfo: ["configuration": configuration]
        )

        // Publish AsyncStream progress (10 Hz)
        #if canImport(Foundation)
        let received = Int64(startOffset)
        let expected = Int64(configuration.info?.contentLength ?? 0)
        let urlCopy = url
        Task {
            let pr = await VideoDownloadManager.shared.currentPriority(for: urlCopy)
            let progress = DownloadProgress(url: urlCopy, receivedBytes: received, expectedBytes: expected > 0 ? expected : nil, priority: pr)
            await VideoDownloadManager.shared.publish(progress)
        }
        #endif
    }
    
    func notifyFinished(error: Error?) {
        let configuration = cacheHandler.configuration
        var userInfo: [AnyHashable: Any] = ["configuration": configuration]
        if let error = error { userInfo[NSURLErrorKey] = error }
        
        NotificationCenter.default.post(
            name: .VideoDownloadDidFinished,
            object: nil,
            userInfo: userInfo
        )
    }
    
}
