//
//  VideoDownloaderSessionDelegateHandler.swift
//  GSPlayer
//
//  Created by Gesen on 2019/4/20.
//  Copyright © 2019 Gesen. All rights reserved.
//

import Foundation

private let bufferSize = 1024 * 256

protocol VideoDownloaderSessionDelegateHandlerDelegate: AnyObject {
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)

}

class VideoDownloaderSessionDelegateHandler: NSObject {

    // Global auth challenge override. If nil, default handling is used.
    var authChallengeHandler: ((URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?

    private class WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    // Per-task delegate routing and buffers
    private var taskDelegates: [Int: WeakBox<AnyObject>] = [:]
    private var buffers: [Int: Data] = [:]

    override init() { }

    func register(task: URLSessionTask, delegate: VideoDownloaderSessionDelegateHandlerDelegate) {
        taskDelegates[task.taskIdentifier] = WeakBox(delegate)
        buffers[task.taskIdentifier] = Data()
    }

    func unregister(task: URLSessionTask) {
        taskDelegates.removeValue(forKey: task.taskIdentifier)
        buffers.removeValue(forKey: task.taskIdentifier)
    }
    
}

extension VideoDownloaderSessionDelegateHandler: URLSessionDataDelegate {
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let handler = authChallengeHandler {
            handler(challenge, completionHandler)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let tid = dataTask.taskIdentifier
        if let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate {
            delegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
        } else {
            completionHandler(.cancel)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tid = dataTask.taskIdentifier
        if buffers[tid] == nil { buffers[tid] = Data() }
        buffers[tid]?.append(data)
        guard let count = buffers[tid]?.count, count > bufferSize else { return }
        callbackBuffer(session: session, dataTask: dataTask)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let tid = task.taskIdentifier
        if let bufferCount = buffers[tid]?.count, bufferCount > 0, error == nil, let dt = task as? URLSessionDataTask {
            callbackBuffer(session: session, dataTask: dt)
        }
        if let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate {
            delegate.urlSession(session, task: task, didCompleteWithError: error)
        }
        unregister(task: task)
        Task { [tid] in
            await VideoDownloadManager.shared.untrack(taskIdentifier: tid)
        }
    }
    
}

private extension VideoDownloaderSessionDelegateHandler {
    
    private func callbackBuffer(session: URLSession, dataTask: URLSessionDataTask) {
        let tid = dataTask.taskIdentifier
        guard let buffer = buffers[tid], let delegate = taskDelegates[tid]?.value as? VideoDownloaderSessionDelegateHandlerDelegate else { return }
        let range: Range<Int> = 0 ..< buffer.count
        let chunk = buffer.subdata(in: range)
        buffers[tid]?.replaceSubrange(range, with: [], count: 0)
        delegate.urlSession(session, dataTask: dataTask, didReceive: chunk)
    }
    
}
