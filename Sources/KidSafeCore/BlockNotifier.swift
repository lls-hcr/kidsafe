import Darwin
import Foundation

/// Notifications « site bloqué » : lit les nouvelles lignes du journal de Privoxy et choisit
/// celles qui méritent d'être montrées. Les blocages invisibles (publicité, pistage, règles
/// de base de Privoxy) sont ignorés, et un même site n'est signalé qu'une fois par période.
public final class BlockNotifier {

    public struct Match: Sendable, Equatable {
        /// Site affiché (le domaine de la liste qui a bloqué, ex. `pornhub.com`).
        public var site: String
        /// Raison : nom de la catégorie, du réseau social, ou « bloqué à la main ».
        public var reason: String
        /// Clé de regroupement : un réseau social n'est signalé qu'une fois, quels que soient ses domaines.
        public var key: String
        public init(site: String, reason: String, key: String) { self.site = site; self.reason = reason; self.key = key }
    }

    /// Catégories dont les blocages ne sont jamais signalés (en arrière-plan sur presque toutes les pages).
    public static let quietCategoryIDs: Set<String> = ["ads", "easylist", "easyprivacy", "liste-fr", "adguard-dns", "stevenblack"]
    /// Un même site n'est signalé qu'une fois pendant cette durée.
    public static let repeatInterval: TimeInterval = 10 * 60

    public let confDir: URL
    private var offset: UInt64?
    private var partial = ""
    private var shown: [String: Date] = [:]
    private var lookups: [String: (date: Date, match: Match?)] = [:]

    public init(confDir: URL) { self.confDir = confDir }

    /// Lit les lignes ajoutées au journal depuis l'appel précédent et renvoie les blocages à signaler
    /// (au plus un par appel, pour ne pas inonder l'écran). Le premier appel ne fait que se placer à la fin.
    public func poll(now: Date = Date()) -> Match? {
        process(readNewEntries(), now: now)
    }

    func process(_ entries: [BlockLog.Entry], now: Date) -> Match? {
        shown = shown.filter { now.timeIntervalSince($0.value) < Self.repeatInterval }
        lookups = lookups.filter { now.timeIntervalSince($0.value.date) < Self.repeatInterval }
        var files: [(name: String, data: Data)]?
        for e in entries where !e.host.isEmpty {
            let match: Match?
            if let cached = lookups[e.host] {
                match = cached.match
            } else {
                if files == nil { files = loadFiles() }
                match = Self.classify(host: e.host, files: files ?? [])
                lookups[e.host] = (now, match)
            }
            guard let match, shown[match.key] == nil else { continue }
            shown[match.key] = now
            return match
        }
        return nil
    }

    // MARK: - Journal

    private func readNewEntries() -> [BlockLog.Entry] {
        let file = BlockLog.logFile(confDir: confDir)
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard let start = offset, start <= size else {   // premier appel, ou journal vidé
            offset = size; partial = ""
            return []
        }
        guard size > start else { return [] }
        try? h.seek(toOffset: max(start, size > 1_000_000 ? size - 1_000_000 : 0))
        let text = partial + String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        offset = size
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()   // ligne pas encore terminée
        return lines.compactMap(BlockLog.parse)
    }

    // MARK: - Recherche dans les listes (sans les charger en mémoire)

    /// Fichiers à consulter, dans l'ordre : domaines bloqués à la main, réseaux sociaux, puis catégories.
    private func loadFiles() -> [(name: String, data: Data)] {
        let quiet = Set(Self.quietCategoryIDs.map(PrivoxyActions.fileName(forCategory:)))
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: confDir.path)) ?? [])
            .filter { $0.hasPrefix(PrivoxyActions.filePrefix + "cat-") && $0.hasSuffix(".action") && !quiet.contains($0) }
            .sorted()
        return ([PrivoxyActions.customBlockFileName, PrivoxyActions.servicesFileName] + names).compactMap { name in
            (try? Data(contentsOf: confDir.appendingPathComponent(name), options: .alwaysMapped)).map { (name, $0) }
        }
    }

    static func classify(host: String, files: [(name: String, data: Data)]) -> Match? {
        let candidates = DomainName.isIPv4(host.utf8) ? [host] : suffixes(of: host.lowercased())
        for (name, data) in files {
            let end = find("\n{ -block }\n", in: data) ?? data.count   // exceptions de la liste : pas un blocage
            for c in candidates {   // du plus précis au plus large, comme Privoxy
                let pattern = DomainName.isIPv4(c.utf8) ? c : "." + c
                guard let at = find("\n" + pattern + "\n", in: data) else { continue }
                guard at < end else { break }   // exception plus précise : cette liste ne bloque pas l'hôte
                guard let reason = reason(before: at, in: data) else { continue }
                let services = name == PrivoxyActions.servicesFileName
                return Match(site: c, reason: reason, key: services ? "service:" + reason : c)
            }
        }
        return nil
    }

    /// `www.a.example.com` → `www.a.example.com`, `a.example.com`, `example.com` (pas le domaine de premier niveau seul).
    static func suffixes(of host: String) -> [String] {
        var out: [String] = [], h = Substring(host)
        while h.contains(".") {
            out.append(String(h))
            h = h[h.index(after: h.firstIndex(of: ".")!)...]
        }
        return out
    }

    /// Raison du dernier bloc `{ +block{KidSafe : …} }` avant la position (en-têtes peu nombreux : recherche vers l'avant).
    static func reason(before position: Int, in data: Data) -> String? {
        let marker = "+block{KidSafe : "
        var from = 0, found: Int?
        while let at = find(marker, in: data, from: from), at < position { found = at; from = at + 1 }
        guard let at = found else { return nil }
        let start = at + marker.utf8.count
        let line = data[data.startIndex + start ..< data.startIndex + min(data.count, start + 200)]
        return String(decoding: line.prefix { $0 != UInt8(ascii: "}") && $0 != UInt8(ascii: "\n") }, as: UTF8.self)
    }

    static func find(_ needle: String, in data: Data, from: Int = 0) -> Int? {
        let n = Array(needle.utf8)
        return data.withUnsafeBytes { raw -> Int? in
            guard let base = raw.baseAddress, from >= 0, raw.count - from >= n.count else { return nil }
            return n.withUnsafeBytes { nb -> Int? in
                guard let p = memmem(base + from, raw.count - from, nb.baseAddress, n.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(p))
            }
        }
    }
}
