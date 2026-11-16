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

    static let corePorts = [8123, 80]

    /// Home Assistant Core, not the landingpage that stands in for it while it
    /// downloads. The landingpage answers 200 on `/` and 401 on every `/api/`
    /// path, so those cannot tell them apart. Core serves the real frontend
    /// (`/manifest.json`) and answers `/api/onboarding` with 200 before
    /// onboarding and 404 after it; the landingpage answers 401 to both.
    static func coreAnswers(onboardingStatus: Int?, manifestStatus: Int?) -> Bool {
        if manifestStatus == 200 { return true }
        return onboardingStatus == 200 || onboardingStatus == 404
    }

    static func coreServingPort(ip: String) async -> Int? {
        for port in corePorts {
            guard let onboarding = URL(string: "http://\(ip):\(port)/api/onboarding"),
                  let manifest = URL(string: "http://\(ip):\(port)/manifest.json") else { continue }
            let onboardingStatus = await status(of: onboarding)
            guard onboardingStatus != nil else { continue }
            let manifestStatus = await status(of: manifest)
            if coreAnswers(onboardingStatus: onboardingStatus, manifestStatus: manifestStatus) {
                return port
            }
        }
        return nil
    }

    static func relayAnswers(ip: String) async -> Bool {
        guard let url = URL(string: "http://\(ip):\(RelayInstall.port)/") else { return false }
        guard let status = await status(of: url) else { return false }
        return status < 500
    }
}
