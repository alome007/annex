import Foundation

enum HTTPProbe {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    static func status(of url: URL) async -> Int? {
        guard let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }

    static func coreAnswers(ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip)/api/") else { return false }
        let status = await status(of: url)
        return status == 200 || status == 401
    }

    static func relayAnswers(ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(RelayInstall.port)/") else { return false }
        guard let status = await status(of: url) else { return false }
        return status < 500
    }
}
