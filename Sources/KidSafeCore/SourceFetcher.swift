import CryptoKit
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
/// Une fiche par source (`.meta.json`) retient l'empreinte du contenu et les en-têtes HTTP de version
/// (`ETag`, `Last-Modified`) : le serveur peut répondre « inchangé » sans renvoyer la liste.
public struct SourceFetcher: Sendable {
    public var cacheDir: URL
    public var maxBytes = 512 * 1024 * 1024

    public init(cacheDir: URL) { self.cacheDir = cacheDir }

    public struct Fetched: Sendable {
        public var data: Data
        /// Téléchargement impossible : copie du cache (voir `dataDate`).
        public var fromCache: Bool
        public var warning: String?
        /// Contenu identique à la vérification précédente.
        public var unchanged = false
        /// Dernier changement connu du contenu.
        public var changed: Date?
        /// Date à laquelle ce contenu a été téléchargé ou confirmé par le serveur.
        public var dataDate: Date?
    }

    /// Progression du téléchargement : octets reçus, octets attendus (0 si inconnu).
    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    /// Fiche d'une source dans le cache.
    struct Meta: Codable, Equatable {
        var sha256: String?
        var etag: String?
        var lastModified: String?
        /// Dernier téléchargement ou confirmation par le serveur.
        var checked: Date?
        /// Dernier changement du contenu.
        var changed: Date?
    }

    public func fetch(_ source: Catalog.Source, progress: Progress? = nil, now: Date = Date()) async throws -> Fetched {
        guard let url = URL(string: source.url), ["https", "file"].contains(url.scheme?.lowercased() ?? "") else {
            throw KidSafeError.insecureURL(source.url)
        }
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent(cacheName(source))
        let metaFile = cached.appendingPathExtension("meta.json")
        var meta = loadMeta(metaFile)
        let hasCache = FileManager.default.fileExists(atPath: cached.path)

        do {
            let raw: Data
            if url.isFileURL {
                raw = try Data(contentsOf: url)
            } else {
                var req = URLRequest(url: url, timeoutInterval: 120)
                req.setValue("Yamoxy/1.0", forHTTPHeaderField: "User-Agent")
                if hasCache {   // « inchangé ? » : sans copie en cache, il faut le contenu complet
                    if let e = meta.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
                    if let m = meta.lastModified { req.setValue(m, forHTTPHeaderField: "If-Modified-Since") }
                }
                let (data, response) = try await download(req, progress: progress)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 304, let data = try? Data(contentsOf: cached), !data.isEmpty {
                    meta.checked = now
                    saveMeta(meta, to: metaFile)
                    return Fetched(data: data, fromCache: false, unchanged: true, changed: meta.changed, dataDate: now)
                }
                if let http, !(200..<300).contains(http.statusCode) {
                    throw KidSafeError.download(source.url, "HTTP \(http.statusCode)")
                }
                meta.etag = http?.value(forHTTPHeaderField: "ETag")
                meta.lastModified = http?.value(forHTTPHeaderField: "Last-Modified")
                raw = data
            }
            guard raw.count <= maxBytes else { throw KidSafeError.tooLarge(source.url) }
            let text = try extract(raw, source: source)
            guard !text.isEmpty else { throw KidSafeError.download(source.url, L("error.emptyFile")) }
            let sha = SHA256.hash(data: text).map { String(format: "%02x", $0) }.joined()
            let unchanged = hasCache && meta.sha256 == sha
            meta.sha256 = sha
            meta.checked = now
            if !unchanged || meta.changed == nil { meta.changed = now }
            try text.write(to: cached, options: .atomic)
            saveMeta(meta, to: metaFile)
            return Fetched(data: text, fromCache: false, unchanged: unchanged, changed: meta.changed, dataDate: now)
        } catch {
            if let data = try? Data(contentsOf: cached), !data.isEmpty {
                let date = meta.checked ?? (try? FileManager.default.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date
                return Fetched(data: data, fromCache: true, warning: L("warning.cacheUsed", "\(error)"),
                               changed: meta.changed, dataDate: date)
            }
            throw error
        }
    }

    /// Téléchargement avec progression (tâche de téléchargement : pas de copie en mémoire avant la fin).
    private func download(_ req: URLRequest, progress: Progress?) async throws -> (Data, URLResponse) {
        guard let progress else { return try await KidSafeHTTP.session.data(for: req) }
        let delegate = ProgressDelegate(progress)
        let (file, response) = try await KidSafeHTTP.session.download(for: req, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: file) }
        return (try Data(contentsOf: file), response)
    }

    private func loadMeta(_ file: URL) -> Meta {
        guard let data = try? Data(contentsOf: file) else { return Meta() }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode(Meta.self, from: data)) ?? Meta()
    }

    private func saveMeta(_ meta: Meta, to file: URL) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(meta).write(to: file, options: .atomic)
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

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yamoxy-\(UUID().uuidString)")
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

/// Suit la progression d'une tâche de téléchargement (au plus une mise à jour toutes les 0,1 s).
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: SourceFetcher.Progress
    private var observation: NSKeyValueObservation?
    private var last = Date.distantPast
    private let lock = NSLock()

    init(_ report: @escaping SourceFetcher.Progress) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        report(0, max(0, task.countOfBytesExpectedToReceive))
        observation = task.progress.observe(\.completedUnitCount) { [weak self, weak task] _, _ in
            guard let self, let task else { return }
            self.lock.lock()
            let now = Date(), due = now.timeIntervalSince(self.last) >= 0.1
            if due { self.last = now }
            self.lock.unlock()
            if due { self.report(task.countOfBytesReceived, max(0, task.countOfBytesExpectedToReceive)) }
        }
    }

    deinit { observation?.invalidate() }
}
