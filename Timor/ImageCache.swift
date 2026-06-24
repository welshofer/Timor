//
//  ImageCache.swift
//  Timor
//
//  Thread-safe image caching for album art with memory and disk tiers
//

import Foundation
import os.log

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

/// Thread-safe image cache with configurable memory limits
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    nonisolated private static let logger = Logger(subsystem: "com.timor.spotify", category: "ImageCache")

    // MARK: - Cache Configuration

    // This is a thread-safe cache (NSCache, a serial ioQueue, pure hashing). The module
    // defaults to MainActor isolation, so its thread-safe internals are marked `nonisolated`
    // to allow off-main access — required for decoding thumbnails on a background thread.
    // `internal` (not `private`) so the thumbnail extension (ImageCacheThumbnails.swift) can
    // reuse these thread-safe internals.
    nonisolated(unsafe) let memoryCache: NSCache<NSString, PlatformImage>
    nonisolated let cacheDirectory: URL?
    nonisolated(unsafe) let fileManager = FileManager.default
    nonisolated let ioQueue = DispatchQueue(label: "com.timor.imagecache.io", qos: .utility)

    /// PERF-2: coalesce concurrent network fetches for the same URL so the inspector and a
    /// scrolling table don't each download the same album art. Lock-guarded (held only for
    /// brief map mutations, never across an await).
    private let inFlightLock = NSLock()
    private var inFlightRequests: [String: Task<PlatformImage?, Never>] = [:]

    /// Maximum number of images in memory cache.
    /// The cache holds tiny (~36KB) downsampled row thumbnails alongside the occasional
    /// full-size inspector image. A low object count evicts thumbnails on large playlists,
    /// forcing a re-decode on re-scroll — so allow plenty of room (cost is still bounded below).
    private let maxMemoryCount = 3000

    /// Maximum total memory cost (128MB) — ~3500 96px thumbnails, or a mix with full-size art.
    private let maxMemoryCost = 128 * 1024 * 1024

    /// Maximum disk cache size (400MB) — full-size source art is reused to decode thumbnails.
    private let maxDiskCacheSize = 400 * 1024 * 1024

    /// Disk cache expiry (7 days)
    private let diskCacheExpiry: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        memoryCache = NSCache<NSString, PlatformImage>()
        memoryCache.countLimit = maxMemoryCount
        memoryCache.totalCostLimit = maxMemoryCost

        // Setup disk cache directory
        if let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            cacheDirectory = cacheDir.appendingPathComponent("AlbumArtCache", isDirectory: true)
            createCacheDirectoryIfNeeded()
        } else {
            cacheDirectory = nil
            Self.logger.warning("Could not create disk cache directory")
        }

        // Schedule periodic cleanup
        scheduleCacheCleanup()
    }

    // MARK: - Public API

    /// Retrieves an image from cache, checking memory first then disk
    func image(for url: String) -> PlatformImage? {
        let key = cacheKey(for: url)

        // Check memory cache first (fast path)
        if let cachedImage = memoryCache.object(forKey: key as NSString) {
            Self.logger.debug("Memory cache hit for: \(url.prefix(50), privacy: .public)")
            return cachedImage
        }

        // Check disk cache (slower path)
        if let diskImage = loadFromDisk(key: key) {
            // Promote to memory cache
            let cost = estimateImageCost(diskImage)
            memoryCache.setObject(diskImage, forKey: key as NSString, cost: cost)
            Self.logger.debug("Disk cache hit for: \(url.prefix(50), privacy: .public)")
            return diskImage
        }

        return nil
    }

    /// Fetches an image from the network, using cache when available
    func image(from urlString: String) async -> PlatformImage? {
        // Check cache first
        if let cached = image(for: urlString) {
            return cached
        }

        // PERF-2: if a fetch for this URL is already in flight, await it instead of
        // starting a second identical download. `withLock` is the async-safe scoped lock
        // (held only for the brief map mutation, never across an await).
        let (task, isNew): (Task<PlatformImage?, Never>, Bool) = inFlightLock.withLock {
            if let existing = inFlightRequests[urlString] {
                return (existing, false)
            }
            let newTask = Task<PlatformImage?, Never> { [weak self] in
                await self?.fetchAndStore(urlString) ?? nil
            }
            inFlightRequests[urlString] = newTask
            return (newTask, true)
        }

        let result = await task.value

        if isNew {
            inFlightLock.withLock { inFlightRequests[urlString] = nil }
        }

        return result
    }

    /// Performs the actual network fetch and stores the result in the cache.
    private func fetchAndStore(_ urlString: String) async -> PlatformImage? {
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = PlatformImage(data: data) else {
                return nil
            }

            // Store in cache
            store(image, for: urlString)

            Self.logger.debug("Fetched and cached image from: \(urlString.prefix(50), privacy: .public)")
            return image
        } catch {
            Self.logger.error("Failed to fetch image: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Stores an image in both memory and disk cache
    func store(_ image: PlatformImage, for url: String) {
        let key = cacheKey(for: url)
        let cost = estimateImageCost(image)

        // Store in memory
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        // Store on disk asynchronously
        ioQueue.async { [weak self] in
            self?.saveToDisk(image: image, key: key)
        }
    }

    /// Removes an image from both caches
    func remove(for url: String) {
        let key = cacheKey(for: url)
        memoryCache.removeObject(forKey: key as NSString)

        ioQueue.async { [weak self] in
            self?.removeFromDisk(key: key)
        }
    }

    /// Clears all cached images
    func clearAll() {
        memoryCache.removeAllObjects()

        ioQueue.async { [weak self] in
            self?.clearDiskCache()
        }
    }

    // MARK: - Private Implementation

    nonisolated func cacheKey(for url: String) -> String {
        // Use SHA256 hash of URL as key for safe filenames
        let data = Data(url.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func estimateImageCost(_ image: PlatformImage) -> Int {
        #if os(macOS)
        // Estimate memory cost based on image dimensions
        guard let rep = image.representations.first else { return 0 }
        return rep.pixelsWide * rep.pixelsHigh * 4 // RGBA
        #else
        // iOS: use CGImage dimensions
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.width * cgImage.height * 4 // RGBA
        #endif
    }

    private func createCacheDirectoryIfNeeded() {
        guard let cacheDirectory = cacheDirectory else { return }
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            do {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create cache directory: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated func diskPath(for key: String) -> URL? {
        cacheDirectory?.appendingPathComponent(key).appendingPathExtension("png")
    }

    private func loadFromDisk(key: String) -> PlatformImage? {
        guard let path = diskPath(for: key),
              fileManager.fileExists(atPath: path.path) else {
            return nil
        }

        // Check if expired
        if let attributes = try? fileManager.attributesOfItem(atPath: path.path),
           let modificationDate = attributes[.modificationDate] as? Date {
            if Date().timeIntervalSince(modificationDate) > diskCacheExpiry {
                // Expired, remove it
                try? fileManager.removeItem(at: path)
                return nil
            }
        }

        #if os(macOS)
        return NSImage(contentsOf: path)
        #else
        return UIImage(contentsOfFile: path.path)
        #endif
    }

    nonisolated func saveToDisk(image: PlatformImage, key: String) {
        guard let path = diskPath(for: key) else { return }

        #if os(macOS)
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        #else
        guard let pngData = image.pngData() else { return }
        #endif

        do {
            try pngData.write(to: path)
            Self.logger.debug("Saved image to disk cache: \(key.prefix(16), privacy: .public)")
        } catch {
            Self.logger.error("Failed to save image to disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeFromDisk(key: String) {
        guard let path = diskPath(for: key) else { return }
        try? fileManager.removeItem(at: path)
    }

    private func clearDiskCache() {
        guard let cacheDirectory = cacheDirectory else { return }
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in contents {
                try fileManager.removeItem(at: file)
            }
            Self.logger.info("Cleared disk cache")
        } catch {
            Self.logger.error("Failed to clear disk cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleCacheCleanup() {
        // Run cleanup every hour
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3600) { [weak self] in
            self?.performCacheCleanup()
            self?.scheduleCacheCleanup()
        }
    }

    private func performCacheCleanup() {
        guard let cacheDirectory = cacheDirectory else { return }

        ioQueue.async { [weak self] in
            guard let self = self else { return }

            do {
                let contents = try self.fileManager.contentsOfDirectory(
                    at: cacheDirectory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                )

                var totalSize = 0
                var fileInfos: [(url: URL, date: Date, size: Int)] = []

                for file in contents {
                    let attributes = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let date = attributes.contentModificationDate ?? Date.distantPast
                    let size = attributes.fileSize ?? 0
                    totalSize += size
                    fileInfos.append((file, date, size))
                }

                // Remove expired files
                let now = Date()
                for info in fileInfos {
                    if now.timeIntervalSince(info.date) > self.diskCacheExpiry {
                        try self.fileManager.removeItem(at: info.url)
                        totalSize -= info.size
                    }
                }

                // If still over limit, remove oldest files
                if totalSize > self.maxDiskCacheSize {
                    let sorted = fileInfos.sorted { $0.date < $1.date }
                    for info in sorted {
                        if totalSize <= self.maxDiskCacheSize {
                            break
                        }
                        try self.fileManager.removeItem(at: info.url)
                        totalSize -= info.size
                    }
                }

                Self.logger.info("Cache cleanup complete. Total size: \(totalSize / 1024 / 1024)MB")
            } catch {
                Self.logger.error("Cache cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - CommonCrypto Bridge
import CommonCrypto
