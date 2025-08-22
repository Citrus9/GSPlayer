//
//  CacheIO.swift
//  GSPlayer
//
//  Minimal actor wrapper around VideoCacheHandler per PRD.
//

import Foundation

actor CacheIO {
    private let handler: VideoCacheHandler
    init(url: URL) throws {
        self.handler = try VideoCacheHandler(url: url)
    }
    func cache(data: Data, for range: NSRange) -> Bool { handler.cache(data: data, for: range) }
    func cachedData(for range: NSRange) -> Data { handler.cachedData(for: range) }
    func set(info: VideoInfo) { handler.set(info: info) }
    func save() { handler.save() }
    var configuration: VideoCacheConfiguration { handler.configuration }
}


