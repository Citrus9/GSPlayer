//
//  VideoDownloader.swift
//  GSPlayer
//
//  Created by Gesen on 2019/4/20.
//  Copyright © 2019 Gesen. All rights reserved.
//

import Foundation

public protocol VideoDownloaderDelegate: AnyObject {
    
    func downloader(_ downloader: VideoDownloader, didReceive response: URLResponse)
    func downloader(_ downloader: VideoDownloader, didReceive data: Data)
    func downloader(_ downloader: VideoDownloader, didFinished error: Error?)
    
}

public class VideoDownloader {
    
    public weak var delegate: VideoDownloaderDelegate?
    
    public let url: URL
    
    var info: VideoInfo? { return cacheHandler.configuration.info }
    
    private let cacheHandler: VideoCacheHandler
    private var downloaderHandler: VideoDownloaderHandler?
    
    public init(url: URL, cacheHandler: VideoCacheHandler) {
        self.url = url
        self.cacheHandler = cacheHandler
    }
    
    public func downloadToEnd(from offset: Int) {
        download(from: offset, length: (info?.contentLength ?? offset) - offset)
    }
    
    public func download(from offset: Int, length: Int) {
        let actions = cacheHandler.actions(for: NSRange(location: offset, length: length))

        downloaderHandler = VideoDownloaderHandler(url: url, actions: actions, cacheHandler: cacheHandler)
        downloaderHandler?.delegate = self
        downloaderHandler?.start()
    }
    
    public func resume() {
        downloaderHandler?.resume()
    }
    
    public func suspend() {
        downloaderHandler?.suspend()
    }
    
    public func cancel() {
        downloaderHandler?.cancel()
        downloaderHandler = nil
    }
    
}

extension VideoDownloader: VideoDownloaderHandlerDelegate {
    
    func handler(_ handler: VideoDownloaderHandler, didReceive response: URLResponse) {
        
        if info == nil, let httpResponse = response as? HTTPURLResponse {
            
            let contentRangeRaw = httpResponse.value(forHeaderKey: "Content-Range")
            
            // Parse Content-Range into start/end/total (total may be unknown "*")
            func parseContentRange(_ header: String) -> (start: Int, end: Int, total: Int?)? {
                let trimmed = header.replacingOccurrences(of: " ", with: "")
                guard trimmed.lowercased().hasPrefix("bytes") else { return nil }
                let remainder = String(trimmed.dropFirst("bytes".count))
                let parts = remainder.split(separator: "/")
                guard parts.count == 2 else { return nil }
                let rangePart = parts[0]
                let totalPart = parts[1]
                if rangePart == "*" {
                    if let total = Int(totalPart) { return (0, total - 1, total) }
                    return nil
                }
                let se = rangePart.split(separator: "-")
                guard se.count == 2, let start = Int(se[0]), let end = Int(se[1]) else { return nil }
                let total: Int? = (totalPart == "*") ? nil : Int(totalPart)
                return (start, end, total)
            }
            
            let parsed = contentRangeRaw.flatMap(parseContentRange(_:))
            let lengthFromRangeTotal = parsed?.total
            let lengthFromRangeLowerBound = parsed.map { $0.end + 1 }
            let lengthFromHeader = httpResponse.value(forHeaderKey: "Content-Length").flatMap { Int($0) }
            let lengthFromExpected = (response.expectedContentLength > 0) ? Int(response.expectedContentLength) : nil
            
            let contentLength = lengthFromRangeTotal
                ?? lengthFromHeader
                ?? lengthFromExpected
                ?? lengthFromRangeLowerBound
                ?? 1
            
            let contentType = httpResponse
                .value(forHeaderKey: "Content-Type") ?? "video/mp4"
            
            let isByteRangeAccessSupported = httpResponse
                .value(forHeaderKey: "Accept-Ranges")?
                .contains("bytes") ?? false
            
            cacheHandler.set(info: VideoInfo(
                contentLength: contentLength,
                contentType: contentType,
                isByteRangeAccessSupported: isByteRangeAccessSupported
            ))
            #if DEBUG
            print("🎥 [GS] 🧠 meta — rawCR=\(contentRangeRaw ?? "-") len=\(contentLength) type=\(contentType) range=\(isByteRangeAccessSupported)")
            #endif
        }
        
        delegate?.downloader(self, didReceive: response)
    }
    
    func handler(_ handler: VideoDownloaderHandler, didReceive data: Data, isLocal: Bool) {
        delegate?.downloader(self, didReceive: data)
    }
    
    func handler(_ handler: VideoDownloaderHandler, didFinish error: Error?) {
        delegate?.downloader(self, didFinished: error)
    }
    
}

private extension HTTPURLResponse {
    
    func value(forHeaderKey key: String) -> String? {
        return allHeaderFields
            .first { $0.key.description.caseInsensitiveCompare(key) == .orderedSame }?
            .value as? String
    }
    
}
