import Foundation

/// Journal des requêtes bloquées par Privoxy (`debug 1024`) : lignes « Crunch: Blocked: … ».
public enum BlockLog {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { "\(date.timeIntervalSince1970)-\(target)" }
        public var date: Date
        public var target: String
        /// Nom d'hôte seul (sans schéma, port ni chemin).
        public var host: String
        public init(date: Date, target: String, host: String) { self.date = date; self.target = target; self.host = host }
    }

    public static func logFile(confDir: URL) -> URL {
        confDir.appendingPathComponent("log/logfile")
    }

    /// Dernières entrées (les plus récentes d'abord), lues dans la fin du fichier.
    public static func recent(_ file: URL, limit: Int = 200) -> [Entry] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var out: [Entry] = []
        for line in text.split(separator: "\n").reversed() {
            if let e = parse(String(line)) { out.append(e) }
            if out.count >= limit { break }
        }
        return out
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// « 2026-11-21 02:30:12.345 0000700001 Crunch: Blocked: example.com:443 »
    static func parse(_ line: String) -> Entry? {
        guard let r = line.range(of: "Crunch: Blocked: ") else { return nil }
        let target = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        let stamp = String(line.prefix(23))
        guard let date = formatter.date(from: stamp) else { return nil }
        var host = target
        if let s = host.range(of: "://") { host = String(host[s.upperBound...]) }
        host = String(host.split(separator: "/").first ?? "")
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) { host = String(host[..<colon]) }
        return Entry(date: date, target: target, host: host)
    }

    /// Vide le journal (Privoxy continue d'écrire dans le même fichier).
    public static func clear(_ file: URL) {
        if let h = try? FileHandle(forWritingTo: file) { try? h.truncate(atOffset: 0); try? h.close() }
    }

    /// Limite la taille du journal (appelé au lancement).
    public static func trim(_ file: URL, maxBytes: UInt64 = 5_000_000) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? UInt64, size > maxBytes else { return }
        clear(file)
    }
}
