import Compression
import Foundation

enum ImageDownloadError: LocalizedError {
    case releaseLookupFailed(String)
    case assetMissing
    case downloadFailed(String)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .releaseLookupFailed(let detail):
            "Could not look up the latest Home Assistant OS release: \(detail)"
        case .assetMissing:
            "The latest Home Assistant OS release has no generic-aarch64 image."
        case .downloadFailed(let detail):
            "The image download failed: \(detail)"
        case .decompressionFailed:
            "The downloaded image is damaged and could not be unpacked. Start again to re-download it."
        }
    }
}

enum ImageDownloader {
    static let releaseAPI = URL(string: "https://api.github.com/repos/home-assistant/operating-system/releases/latest")!

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

    static func downloadLatest(progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        let asset = try await latestImageAsset()
        try Paths.ensureSupportDirectory()
        let destination = Paths.support.appending(path: asset.name)
        let temporary = try await Downloader().download(from: asset.url, progress: progress)
        if let stale = cachedArchive {
            try? FileManager.default.removeItem(at: stale)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private struct Asset {
        let name: String
        let url: URL
    }

    private static func latestImageAsset() async throws -> Asset {
        struct Release: Decodable {
            struct ReleaseAsset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let assets: [ReleaseAsset]
        }
        var request = URLRequest(url: releaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ImageDownloadError.releaseLookupFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ImageDownloadError.releaseLookupFailed("GitHub answered with status \(status).")
        }
        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw ImageDownloadError.releaseLookupFailed("Unexpected response format.")
        }
        guard let name = imageAssetName(inReleaseAssetNames: release.assets.map(\.name)),
              let asset = release.assets.first(where: { $0.name == name }) else {
            throw ImageDownloadError.assetMissing
        }
        return Asset(name: asset.name, url: asset.browser_download_url)
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
