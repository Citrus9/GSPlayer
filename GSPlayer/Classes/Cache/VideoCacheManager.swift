//
//  VideoCacheManager.swift
//  GSPlayer
//
//  Created by Gesen on 2019/4/20.
//  Copyright © 2019 Gesen. All rights reserved.
//

import Foundation
import UniformTypeIdentifiers

//private let directory = NSTemporaryDirectory().appendingPathComponent("GSPlayer")

private let directory: String = {
    let cachesDir = FileManager.default.urls(for: .cachesDirectory, 
                                            in: .userDomainMask).first!
    return cachesDir.appendingPathComponent("GSPlayer").path
}()

public enum VideoCacheManager {
    
    public static func cachedFilePath(for url: URL, contentType: String? = nil) -> String {
        let base = directory.appendingPathComponent(url.absoluteString.md5)
        let ext: String = {
            let p = url.pathExtension
            if !p.isEmpty { return p }
            if let mime = contentType, let ut = UTType(mimeType: mime), let e = ut.preferredFilenameExtension { return e }
            return "mp4"
        }()
        return base.appendingPathExtension(ext)!
    }
    
    public static func cachedConfiguration(for url: URL) throws -> VideoCacheConfiguration {
        return try VideoCacheConfiguration
            .configuration(for: cachedFilePath(for: url))
    }
    
    public static func calculateCachedSize() -> UInt {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey]
        
        let fileContents = (try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: Array(resourceKeys), options: .skipsHiddenFiles)) ?? []
        
        return fileContents.reduce(0) { size, fileContent in
            guard
                let resourceValues = try? fileContent.resourceValues(forKeys: resourceKeys),
                resourceValues.isDirectory != true,
                let fileSize = resourceValues.totalFileAllocatedSize
                else { return size }
            
            return size + UInt(fileSize)
        }
    }
    
    public static func cleanAllCache() throws {
        let fileManager = FileManager.default
        let fileContents = try fileManager.contentsOfDirectory(atPath: directory)
        
        for fileContent in fileContents {
            let filePath = directory.appendingPathComponent(fileContent)
            try fileManager.removeItem(atPath: filePath)
        }
    }
    
}
