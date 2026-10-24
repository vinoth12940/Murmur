import Foundation

/// Checks GitHub for a newer release. Only ever runs when the user picks "Check for Updates…":
/// Murmur makes no background network requests.
enum Updater {
    static let repository = "vinoth12940/Murmur"

    struct Release {
        let version: String
        let page: URL
    }

    enum UpdateError: LocalizedError {
        case badResponse
        var errorDescription: String? { "GitHub returned an unexpected answer." }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when `remote` is a higher version than `local`. Understands a leading "v", missing
    /// components ("1.0" == "1.0.0") and ignores "-beta"/"+build" suffixes. Unparseable input is never "newer".
    static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let r = components(remote), let l = components(local) else { return false }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    static func checkLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Murmur/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let link = json["html_url"] as? String, let page = URL(string: link), page.host == "github.com"
        else { throw UpdateError.badResponse }
        return Release(version: tag, page: page)
    }
}
