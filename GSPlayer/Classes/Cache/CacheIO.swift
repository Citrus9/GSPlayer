//
//  CacheIO.swift
//  GSPlayer
//
//  Minimal actor wrapper around VideoCacheHandler per PRD.
//

import Foundation

actor CacheIO {
    private let handler: VideoCacheHandler
    private var pendingSave = false
    private var lastSave: CFAbsoluteTime = 0

    init(url: URL) throws {
        self.handler = try VideoCacheHandler(url: url)
    }

    init(handler: VideoCacheHandler) {
        self.handler = handler
    }

    func cache(data: Data, for range: NSRange) -> Bool { handler.cache(data: data, for: range) }
    func cachedData(for range: NSRange) -> Data { handler.cachedData(for: range) }
    func set(info: VideoInfo) { handler.set(info: info) }
    func saveNow() {
        guard pendingSave else { return }
        handler.save()
        pendingSave = false
        lastSave = CFAbsoluteTimeGetCurrent()
    }
    func saveDebounced() {
        pendingSave = true
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSave > 0.25 {
            handler.save()
            pendingSave = false
            lastSave = now
        }
    }
    var configuration: VideoCacheConfiguration { handler.configuration }
}


