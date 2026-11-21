import Foundation

/// Recherche d'une nouvelle version de KidSafe sur GitHub (dernière « release » publiée).
/// Aucune donnée personnelle n'est envoyée : une simple requête à l'API publique de GitHub.
public struct UpdateChecker: Sendable {
    public struct Release: Sendable, Equatable {
        public var version: String
        public var pageURL: URL
        public var downloadURL: URL?
        /// Empreinte SHA-256 du .dmg (champ `digest` de GitHub, sinon notes de version). Sans elle, pas d'installation automatique.
        public var dmgSHA256: String?
        public init(version: String, pageURL: URL, downloadURL: URL?, dmgSHA256: String? = nil) {
            self.version = version; self.pageURL = pageURL; self.downloadURL = downloadURL; self.dmgSHA256 = dmgSHA256
        }
    }

    public enum CheckError: Error, CustomStringConvertible {
        case network(String), badResponse
        public var description: String {
            switch self {
            case .network(let why): return why
            case .badResponse: return L("updates.error.response")
            }
        }
    }

    /// Ex. https://api.github.com/repos/lls-hcr/kidsafe/releases/latest
    public var apiURL: URL
    public init(apiURL: URL) { self.apiURL = apiURL }

    public func latest(userAgent: String) async throws -> Release {
        var req = URLRequest(url: apiURL, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: req) } catch { throw CheckError.network(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw CheckError.badResponse }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { var name: String; var browser_download_url: URL; var digest: String? }
        struct Payload: Decodable { var tag_name: String; var html_url: URL; var assets: [Asset]?; var draft: Bool?; var prerelease: Bool?; var body: String? }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.draft != true else { throw CheckError.badResponse }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        let dmg = p.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
        var sha = dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        if sha == nil, let body = p.body,
           let r = body.range(of: #"SHA-256 `KidSafe\.dmg`\s*:\s*`([0-9a-fA-F]{64})`"#, options: .regularExpression) {
            sha = String(body[r].suffix(65).dropLast())
        }
        return Release(version: version, pageURL: p.html_url, downloadURL: dmg?.browser_download_url, dmgSHA256: sha?.lowercased())
    }

    /// Vrai si `candidate` est plus récente que `current` (« 0.10.0 » > « 0.9.2 »).
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
