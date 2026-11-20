import Foundation

public enum KidSafeError: Error, CustomStringConvertible {
    case insecureURL(String)
    case download(String, String)
    case tooLarge(String)
    case archive(String, String)
    case configTestFailed(String)
    case io(String)

    public var description: String {
        switch self {
        case .insecureURL(let u): return L("error.insecureURL", u)
        case .download(let u, let why): return L("error.download", u, why)
        case .tooLarge(let u): return L("error.tooLarge", u)
        case .archive(let u, let why): return L("error.archive", u, why)
        case .configTestFailed(let out): return L("error.configTest", out)
        case .io(let why): return why
        }
    }
}

/// Télécharge une source (certificat TLS vérifié) et la garde en cache :
/// si le téléchargement échoue plus tard, la dernière version connue est réutilisée.
public struct SourceFetcher: Sendable {
    public var cacheDir: URL
    public var maxBytes = 512 * 1024 * 1024

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    public struct Fetched: Sendable {
        public var data: Data
        public var fromCache: Bool
        public var warning: String?
    }

    public func fetch(_ source: Catalog.Source) async throws -> Fetched {
        guard let url = URL(string: source.url), ["https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw KidSafeError.insecureURL(source.url)
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent(cacheName(source))

        do {
            let raw: Data
            if url.isFileURL {
                raw = try Data(contentsOf: url)
            } else {
                var req = URLRequest(url: url, timeoutInterval: 120)
                req.setValue("KidSafe-blocklist/1.0", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw KidSafeError.download(source.url, "HTTP \(http.statusCode)")
                }
                raw = data
            }
            guard raw.count <= maxBytes else { throw KidSafeError.tooLarge(source.url) }
            let text = try extract(raw, source: source)
            guard !text.isEmpty else { throw KidSafeError.download(source.url, L("error.emptyFile")) }
            try text.write(to: cached, options: .atomic)
            return Fetched(data: text, fromCache: false)
        } catch {
            if let data = try? Data(contentsOf: cached), !data.isEmpty {
                return Fetched(data: data, fromCache: true,
                               warning: L("warning.cacheUsed", "\(error)"))
            }
            throw error
        }
    }

    private func cacheName(_ s: Catalog.Source) -> String {
        let key = s.url + "|" + (s.archiveMember ?? "")
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe.suffix(150)) + ".txt"
    }

    private func extract(_ raw: Data, source: Catalog.Source) throws -> Data {
        let path = (URL(string: source.url)?.path ?? source.url).lowercased()
        let isTar = path.hasSuffix(".tar.gz") || path.hasSuffix(".tgz") || path.hasSuffix(".tar")
        let isGz = !isTar && path.hasSuffix(".gz")
        guard isTar || isGz else { return raw }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent(isTar ? "src.tar.gz" : "src.gz")
        try raw.write(to: archive)

        if isGz {
            return try run("/usr/bin/gunzip", ["-c", archive.path], source: source)
        }
        guard let member = source.archiveMember, !member.hasPrefix("/"), !member.contains("..") else {
            throw KidSafeError.archive(source.url, L("error.archiveMember"))
        }
        // -O : écrit le membre sur la sortie standard, rien n'est extrait sur le disque.
        return try run("/usr/bin/tar", ["-xzOf", archive.path, member], source: source)
    }

    private func run(_ tool: String, _ args: [String], source: Catalog.Source) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw KidSafeError.archive(source.url, String(decoding: errData, as: UTF8.self))
        }
        return data
    }
}
