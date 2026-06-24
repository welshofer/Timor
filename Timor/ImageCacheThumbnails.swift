//
//  ImageCacheThumbnails.swift
//  Timor
//
//  Downsampled-thumbnail support for ImageCache, kept in its own file so the heavy,
//  scroll-critical decode path is isolated from the core cache.
//

import Foundation
import ImageIO

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Downsampled Thumbnails (scroll performance)

extension ImageCache {

    /// Memory-only thumbnail lookup — synchronous, no disk IO, safe to call on the main
    /// thread for every visible/recycled table row. Returns nil if not yet decoded.
    func cachedThumbnail(for urlString: String, maxPixel: CGFloat) -> PlatformImage? {
        let key = cacheKey(for: "thumb:\(Int(maxPixel)):\(urlString)") as NSString
        return memoryCache.object(forKey: key)
    }

    /// Returns a thumbnail whose longest side is ~`maxPixel` PIXELS. All disk IO and image
    /// decoding happen OFF the main thread, and the small result is memory-cached so recycled
    /// rows get an instant hit. This is what keeps the track table scrolling smooth — it avoids
    /// reading and decoding full-resolution (e.g. 640×640) art on the main thread per row.
    func thumbnail(for urlString: String, maxPixel: CGFloat) async -> PlatformImage? {
        if let cached = cachedThumbnail(for: urlString, maxPixel: maxPixel) {
            return cached
        }
        return await Task.detached(priority: .utility) { [weak self] () -> PlatformImage? in
            guard let self = self else { return nil }
            guard let data = await self.sourceData(for: urlString),
                  let thumb = ImageCache.downsample(data: data, maxPixel: maxPixel) else {
                return nil
            }
            let key = self.cacheKey(for: "thumb:\(Int(maxPixel)):\(urlString)") as NSString
            self.memoryCache.setObject(thumb, forKey: key, cost: Int(maxPixel * maxPixel * 4))
            return thumb
        }.value
    }

    /// Returns the raw bytes for an image: from the on-disk full image if present, otherwise
    /// from the network (also persisting the full image to disk for later full-size use).
    nonisolated private func sourceData(for urlString: String) async -> Data? {
        let key = cacheKey(for: urlString)
        if let path = diskPath(for: key),
           fileManager.fileExists(atPath: path.path),
           let data = try? Data(contentsOf: path) {
            return data
        }
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            if let full = PlatformImage(data: data) {
                ioQueue.async { [weak self] in self?.saveToDisk(image: full, key: key) }
            }
            return data
        } catch {
            return nil
        }
    }

    /// Decodes a downsampled thumbnail directly from encoded bytes using ImageIO. This decodes
    /// only the pixels needed for the target size, rather than the full image.
    nonisolated private static func downsample(data: Data, maxPixel: CGFloat) -> PlatformImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
