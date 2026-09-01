import Foundation
import Observation

/// Asks GitHub whether a newer release exists, and remembers when it last asked.
///
/// The source of truth is the repo's **latest release** — the same place a download would
/// come from, so the check can never claim a version nobody can get. While the repo is
/// private, or has no releases yet, the request 404s and the app simply reports that it
/// couldn't check; the day releases exist, this starts working with no code change.
///
/// Checking is quiet: once a day on launch, and on demand from Settings. Nothing nags —
/// Home shows one row while an update is known to exist, and that is the whole campaign.
@MainActor
@Observable
final class UpdateChecker {

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// The newest release, when there is one the user doesn't have.
    var available: (version: String, url: URL)? {
        if case .available(let version, let url) = status { return (version, url) }
        return nil
    }

    private let defaults: UserDefaults
    private let releasesURL: URL

    private enum Key {
        static let lastChecked = "update.lastCheckedAt"
    }

    /// A day, because releases are not emergencies and the check is a network request.
    private static let staleAfter: TimeInterval = 24 * 60 * 60

    init(
        defaults: UserDefaults = .standard,
        releasesURL: URL = URL(
            string: "https://api.github.com/repos/mcathala/murmr-flow/releases/latest"
        )!
    ) {
        self.defaults = defaults
        self.releasesURL = releasesURL
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The launch-time check: only if a day has passed, and never surfacing failures —
    /// an offline launch must not open the app with an error about a nicety.
    func checkIfStale() async {
        let last = defaults.double(forKey: Key.lastChecked)
        guard Date().timeIntervalSince1970 - last > Self.staleAfter else { return }
        await check(quietly: true)
    }

    /// The button's check: reports whatever happens, including failure.
    func check() async {
        await check(quietly: false)
    }

    private func check(quietly: Bool) async {
        status = .checking
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastChecked)

        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 404 is what a repo with no public releases returns — say what it
                // means, not the number.
                let message = code == 404
                    ? "No public releases yet."
                    : "The update check failed (HTTP \(code))."
                status = quietly ? .idle : .failed(message)
                return
            }

            struct Release: Decodable {
                let tagName: String
                let htmlUrl: URL
                enum CodingKeys: String, CodingKey {
                    case tagName = "tag_name"
                    case htmlUrl = "html_url"
                }
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.normalized(release.tagName)

            status = Self.isNewer(latest, than: currentVersion)
                ? .available(version: latest, url: release.htmlUrl)
                : .upToDate
        } catch {
            status = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    // MARK: - Versions

    /// "v1.2.3" and "1.2.3" are the same release; tags usually carry the prefix.
    nonisolated static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric, segment by segment, missing segments read as zero — so "1.2" and "1.2.0"
    /// are the same version and "0.0.10" beats "0.0.9", which string comparison gets wrong.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = normalized(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let rhs = normalized(current).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
