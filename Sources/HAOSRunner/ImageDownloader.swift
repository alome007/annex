import Compression
import Foundation

struct HAOSRelease: Equatable, Identifiable {
    let version: String
    let assetName: String
    let assetURL: URL
    let notesURL: URL?

    var id: String { version }
}

enum ImageDownloadError: LocalizedError {
    case releaseLookupFailed(String)
    case assetMissing
    case downloadFailed(String)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .releaseLookupFailed(let detail):
            "Could not fetch the Home Assistant OS releases: \(detail) "
                + "Check your internet connection and start again, or pick an image manually in settings."
        case .assetMissing:
            "No matching Home Assistant OS release with a generic-aarch64 image was found. Pick an image manually in settings."
        case .downloadFailed(let detail):
            "The image download failed: \(detail) Start again to retry, or pick an image manually in settings."
        case .decompressionFailed:
            "The downloaded image is damaged and could not be unpacked. Start again to re-download it."
        }
    }
}

enum ImageDownloader {
    static let releasesAPI = URL(string: "https://api.github.com/repos/home-assistant/operating-system/releases?per_page=20")!

    static func imageAssetName(inReleaseAssetNames names: [String]) -> String? {
        names.first { $0.hasPrefix("haos_generic-aarch64-") && $0.hasSuffix(".img.xz") }
    }

    static var cachedArchive: URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: Paths.support, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents
            .filter { imageAssetName(inReleaseAssetNames: [$0.lastPathComponent]) != nil }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
    }

    static func releases(fromJSON data: Data) -> [HAOSRelease]? {
        struct APIRelease: Decodable {
            struct APIAsset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let prerelease: Bool
            let html_url: URL?
            let assets: [APIAsset]
        }
        guard let decoded = try? JSONDecoder().decode([APIRelease].self, from: data) else { return nil }
        return decoded.compactMap { release in
            guard !release.prerelease,
                  let assetName = imageAssetName(inReleaseAssetNames: release.assets.map(\.name)),
                  let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
            return HAOSRelease(
                version: release.tag_name,
                assetName: assetName,
                assetURL: asset.browser_download_url,
                notesURL: release.html_url
            )
        }
    }

    static func fetchReleases() async throws -> [HAOSRelease] {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = ReleaseCache.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if let cached = ReleaseCache.load() { return cached }
            throw ImageDownloadError.releaseLookupFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ImageDownloadError.releaseLookupFailed("Unexpected response.")
        }
        switch http.statusCode {
        case 200:
            if let releases = releases(fromJSON: data), !releases.isEmpty {
                ReleaseCache.store(data: data, etag: http.value(forHTTPHeaderField: "ETag"))
                return releases
            }
            if let cached = ReleaseCache.load() { return cached }
            throw ImageDownloadError.releaseLookupFailed(
                "GitHub's answer could not be read — something on this network may be intercepting the connection."
            )
        case 304:
            guard let cached = ReleaseCache.load() else {
                ReleaseCache.clear()
                throw ImageDownloadError.releaseLookupFailed("The release cache is missing.")
            }
            return cached
        default:
            if let cached = ReleaseCache.load() { return cached }
            throw ImageDownloadError.releaseLookupFailed("GitHub answered with status \(http.statusCode).")
        }
    }

    static func download(release: HAOSRelease, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        try Paths.ensureSupportDirectory()
        let destination = Paths.support.appending(path: release.assetName)
        let temporary = try await Downloader().download(from: release.assetURL, progress: progress)
        if let stale = cachedArchive {
            try? FileManager.default.removeItem(at: stale)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    static func decompress(archive: URL, to output: URL) throws {
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: output.path(percentEncoded: false), contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        do {
            let filter = try OutputFilter(.decompress, using: .lzma) { data in
                if let data { writer.write(data) }
            }
            while true {
                let chunk = try input.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { break }
                try filter.write(chunk)
            }
            try filter.finalize()
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw ImageDownloadError.decompressionFailed
        }
    }

    private enum ReleaseCache {
        private static let etagKey = "releaseListETag"
        private static var file: URL { Paths.support.appending(path: "releases-cache.json") }

        static var etag: String? { Persistence.defaults.string(forKey: etagKey) }

        static func store(data: Data, etag: String?) {
            try? Paths.ensureSupportDirectory()
            try? data.write(to: file)
            Persistence.defaults.set(etag, forKey: etagKey)
        }

        static func load() -> [HAOSRelease]? {
            guard let data = try? Data(contentsOf: file),
                  let releases = releases(fromJSON: data), !releases.isEmpty else { return nil }
            return releases
        }

        static func clear() {
            try? FileManager.default.removeItem(at: file)
            Persistence.defaults.removeObject(forKey: etagKey)
        }
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private var progressHandler: (@Sendable (Int) -> Void)?
        private var continuation: CheckedContinuation<URL, Error>?
        private var movedFile: URL?
        private var lastPercent = -1

        func download(from url: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
            progressHandler = progress
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let percent = Int(totalBytesWritten * 100 / totalBytesExpectedToWrite)
            guard percent != lastPercent else { return }
            lastPercent = percent
            progressHandler?(percent)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let holding = FileManager.default.temporaryDirectory.appending(path: "haos-download-\(ProcessInfo.processInfo.globallyUniqueString)")
            do {
                try FileManager.default.moveItem(at: location, to: holding)
                movedFile = holding
            } catch {
                movedFile = nil
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error {
                continuation.resume(throwing: ImageDownloadError.downloadFailed(error.localizedDescription))
            } else if let http = task.response as? HTTPURLResponse, http.statusCode != 200 {
                continuation.resume(throwing: ImageDownloadError.downloadFailed("GitHub answered with status \(http.statusCode)."))
            } else if let movedFile {
                continuation.resume(returning: movedFile)
            } else {
                continuation.resume(throwing: ImageDownloadError.downloadFailed("The downloaded file could not be saved."))
            }
        }
    }
}
