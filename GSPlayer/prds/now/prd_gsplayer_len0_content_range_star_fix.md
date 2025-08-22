## PRD: GSPlayer — Fix len=0 content info (Content-Range "*" / missing total) causing −11829

### Context
- Symptom: Opening a specific video shows logs with correct UTType but `len=0`, then AVFoundation error `−11829 Cannot Open` and black playback.
- Observed logs:
  - `🎥 [GS] 🧠 contentInfo — utType=public.mpeg-4 len=0 range=true`
  - `🎥 [VID] ❌ error — -11829 Cannot Open`

### Root cause
- Our content metadata population sets `contentLength` to 0 when servers respond with either:
  - `Content-Range: bytes start-end/*` (unknown total, indicated by `*`), or
  - No `Content-Range` and no `Content-Length` (e.g., chunked or CDN quirks).
- With `contentLength=0` we subsequently:
  - Pass `0` into `AVAssetResourceLoadingContentInformationRequest.contentLength`, which can trigger `−11829` on reopen/play.
  - Truncate the cache file to 0 bytes in `VideoCacheHandler.set(info:)`, corrupting any partially written cache and further amplifying reopen failures.

### Goals
- Never publish `contentLength=0` to AVFoundation.
- Never truncate cache file to 0 when total size is unknown.
- Derive a safe, positive length when the server does not provide a total, and update it if/when a better length becomes available.
- Improve diagnostics for range header parsing.

### High-level approach
1) Robust `Content-Range` parsing supporting unknown totals ("*") and computing a best-effort length as `end + 1` when total is missing.
2) Fallbacks: if both `Content-Range` and `Content-Length` are not usable, use the known requested range or `response.expectedContentLength` (if > 0) to ensure a positive value.
3) Guard truncation: only truncate when `contentLength > 0`.
4) Ensure `contentInformationRequest.contentLength` is always > 0 (or a best-effort lower bound) before assigning.
5) Add bright logs for raw `Content-Range` and the chosen effective length.

### Detailed changes (with code snippets)

#### 1) Robust `Content-Range` parsing and safe length computation
File(s): `VideoDownloader.swift`

```swift
// Add a small helper near VideoDownloader or as a private function
private func parseContentRange(_ header: String) -> (start: Int, end: Int, total: Int?)? {
    // Expected forms:
    // - bytes 0-1048575/7340032
    // - bytes 0-1048575/*
    // - bytes */7340032 (rare)
    let parts = header.replacingOccurrences(of: " ", with: "").split(separator: " ")
    guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
    let rangeAndTotal = parts[1].split(separator: "/")
    guard rangeAndTotal.count == 2 else { return nil }
    let rangePart = rangeAndTotal[0]
    let totalPart = rangeAndTotal[1]

    if rangePart == "*" {
        // Unknown start/end but known total
        if let total = Int(totalPart) { return (0, total - 1, total) }
        return nil
    }

    let se = rangePart.split(separator: "-")
    guard se.count == 2, let start = Int(se[0]), let end = Int(se[1]) else { return nil }
    let total: Int? = (totalPart == "*") ? nil : Int(totalPart)
    return (start, end, total)
}

// In VideoDownloader.handler(_:, didReceive:)
if info == nil, let httpResponse = response as? HTTPURLResponse {
    let contentRangeRaw = httpResponse.value(forHeaderKey: "Content-Range")
    let parsed = contentRangeRaw.flatMap(parseContentRange(_:))

    // 1) Prefer total from Content-Range if present
    let lengthFromRangeTotal = parsed?.total

    // 2) If total is unknown (e.g., bytes 0-1048575/*), use end + 1 as a safe lower bound (> 0)
    let lengthFromRangeLowerBound = parsed.map { $0.end + 1 }

    // 3) Fallbacks
    let lengthFromHeader = httpResponse.value(forHeaderKey: "Content-Length").flatMap { Int($0) }
    let lengthFromExpected = (response.expectedContentLength > 0) ? Int(response.expectedContentLength) : nil

    let contentLength = lengthFromRangeTotal
        ?? lengthFromHeader
        ?? lengthFromExpected
        ?? lengthFromRangeLowerBound
        ?? 1 // never 0; use 1 as last-resort placeholder

    let contentType = httpResponse.value(forHeaderKey: "Content-Type") ?? "video/mp4"
    let isByteRangeAccessSupported = httpResponse.value(forHeaderKey: "Accept-Ranges")?.contains("bytes") ?? false

    cacheHandler.set(info: VideoInfo(
        contentLength: contentLength,
        contentType: contentType,
        isByteRangeAccessSupported: isByteRangeAccessSupported
    ))
    #if DEBUG
    print("🎥 [GS] 🧠 meta — rawCR=\(contentRangeRaw ?? "-") len=\(contentLength) type=\(contentType) range=\(isByteRangeAccessSupported)")
    #endif
}
```

Why this works:
- If total is unknown (`*`), we still compute a positive lower bound from the returned range (`end + 1`). AVFoundation tolerates a lower bound; `0` is the problematic value.
- On 200 responses without `Content-Range`, `Content-Length` or `expectedContentLength` (when positive) are used.
- We never deliver `0` to the rest of the pipeline.

#### 2) Guard truncation when length is unknown
File: `VideoCacheHandler.swift`

```swift
func set(info: VideoInfo) {
    objc_sync_enter(writeFileHandle)
    let previous = configuration.info
    configuration.info = info
    // Only truncate when length is a valid positive number
    if info.contentLength > 0 {
        writeFileHandle.truncateFile(atOffset: UInt64(info.contentLength))
    } else if let prev = previous, prev.contentLength > 0 {
        // Preserve previous known-good size; do not shrink to 0
        writeFileHandle.truncateFile(atOffset: UInt64(prev.contentLength))
    }
    writeFileHandle.synchronizeFile()
    objc_sync_exit(writeFileHandle)
}
```

Why: Avoids truncating to 0 bytes when the total is unknown at first response.

#### 3) Ensure `contentInformationRequest.contentLength` is > 0
File: `VideoRequestLoader.swift`

```swift
// In fulfillContentInfomation()
guard let info = downloader.info, let cir = request.contentInformationRequest else { return }

let mime = info.contentType
let utType = UTType(mimeType: mime)
    ?? UTType(filenameExtension: downloader.url.pathExtension)
    ?? .mpeg4Movie

// Derive a safe, positive length if info.contentLength <= 0
var effectiveLength = info.contentLength
if effectiveLength <= 0 {
    if let dr = request.dataRequest {
        // Lower bound: requested end
        effectiveLength = max(1, Int(dr.requestedOffset) + dr.requestedLength)
    } else {
        effectiveLength = 1 // last resort, never 0
    }
}

cir.contentType = utType.identifier
cir.contentLength = Int64(effectiveLength)
cir.isByteRangeAccessSupported = info.isByteRangeAccessSupported
#if DEBUG
print("🎥 [GS] 🧠 contentInfo — utType=\(utType.identifier) len=\(cir.contentLength) range=\(cir.isByteRangeAccessSupported)")
#endif
```

Why: Guarantees AVFoundation sees a strictly positive `contentLength` even when the server did not provide a total yet.

#### 4) Diagnostics for `Content-Range`
File: `VideoDownloaderHandler.swift`

```swift
func urlSession(_ session: URLSession,
                dataTask: URLSessionDataTask,
                didReceive response: URLResponse,
                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
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
    delegate?.handler(self, didReceive: response)
    completionHandler(.allow)
}
```

### Risks and mitigations
- Reporting a lower bound (e.g., `end+1`) until total is known could cause premature perceived end-of-stream in exotic cases.
  - Mitigation: When a later response provides a higher total, `set(info:)` will truncate to the new larger size and subsequent requests continue normally.
- Some CDNs may omit all helpful headers on first range.
  - Mitigation: We still ensure positive length via request bounds or `expectedContentLength`.

### Acceptance criteria
- No `contentInfo len=0` is logged; all contentInfo lines show `len>0`.
- The previously failing video opens and plays; no reproducible `−11829` on first open or reopen.
- Cache file is never truncated to 0 during normal operation.

### Testing checklist
1) CDN variant returning `Content-Range: bytes 0-1048575/*` — verify `len` equals `end+1` and playback succeeds.
2) 206 with `Content-Range: bytes 0-1048575/7340032` — verify `len` equals total (7,340,032).
3) 200 with `Content-Length` present — verify `len` equals header.
4) 200 without `Content-Length` but `expectedContentLength` > 0 — verify fallback works.
5) No header at all on first response — verify `len>=1` via requested range lower bound and no `−11829`.


