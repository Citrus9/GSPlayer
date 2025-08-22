//
//  VideoRequestLoader.swift
//  GSPlayer
//
//  Created by Gesen on 2019/4/20.
//  Copyright © 2019 Gesen. All rights reserved.
//

import AVFoundation
import UniformTypeIdentifiers

protocol VideoRequestLoaderDelegate: AnyObject {
    
    func loader(_ loader: VideoRequestLoader, didFinish error: Error?)
    
}

class VideoRequestLoader {
    
    weak var delegate: VideoRequestLoaderDelegate?
    
    let request: AVAssetResourceLoadingRequest
    
    private let downloader: VideoDownloader
    
    init(request: AVAssetResourceLoadingRequest, downloader: VideoDownloader) {
        self.request = request
        self.downloader = downloader
        self.downloader.delegate = self
        self.fulfillContentInfomation()
    }
    
    func start() {
        guard
            let dataRequest = request.dataRequest else {
            return
        }
        
        var offset = Int(dataRequest.requestedOffset)
        let length = Int(dataRequest.requestedLength)

        if dataRequest.currentOffset != 0 {
            offset = Int(dataRequest.currentOffset)
        }
        
        if dataRequest.requestsAllDataToEndOfResource {
            downloader.downloadToEnd(from: offset)
        } else {
            downloader.download(from: offset, length: length)
        }
    }
    
    func cancel() {
        downloader.cancel()
    }
    
    func finish() {
        if !request.isFinished {
            request.finishLoading(with: NSError(
                domain: "me.gesen.player.loader",
                code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "Video load request is canceled"])
            )
        }
    }
    
}

extension VideoRequestLoader: VideoDownloaderDelegate {
    
    func downloader(_ downloader: VideoDownloader, didReceive response: URLResponse) {
        fulfillContentInfomation()
    }
    
    func downloader(_ downloader: VideoDownloader, didReceive data: Data) {
        request.dataRequest?.respond(with: data)
    }
    
    func downloader(_ downloader: VideoDownloader, didFinished error: Error?) {
        guard (error as NSError?)?.code != NSURLErrorCancelled else { return }
        
        if error == nil {
            request.finishLoading()
        } else {
            request.finishLoading(with: error)
        }
        
        delegate?.loader(self, didFinish: error)
    }
    
}

private extension VideoRequestLoader {
    
    func fulfillContentInfomation() {
        guard
            let info = downloader.info,
            request.contentInformationRequest != nil else {
            return
        }
        
        let mime = info.contentType
        let utType = UTType(mimeType: mime)
            ?? UTType(filenameExtension: downloader.url.pathExtension)
            ?? .mpeg4Movie
        request.contentInformationRequest?.contentType = utType.identifier
        request.contentInformationRequest?.contentLength = Int64(max(info.contentLength, 0))
        request.contentInformationRequest?.isByteRangeAccessSupported = info.isByteRangeAccessSupported
        #if DEBUG
        print("🎥 [GS] 🧠 contentInfo — utType=\(utType.identifier) len=\(request.contentInformationRequest?.contentLength ?? 0) range=\(request.contentInformationRequest?.isByteRangeAccessSupported ?? false)")
        #endif
    }
    
}
