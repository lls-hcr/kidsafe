import Foundation

/// Résultat de l'analyse d'une ou plusieurs listes.
public struct ParsedBlocklist: Sendable, Equatable {
    /// Domaines (ou adresses IPv4) à bloquer, normalisés.
    public var blocked: Set<String> = []
    /// Exceptions trouvées dans la liste elle-même (règles `@@||domaine^`).
    public var allowed: Set<String> = []
    public var stats = Stats()

    public struct Stats: Sendable, Equatable {
        public var lines = 0
        public var comments = 0
        /// Règles valides mais inutiles pour un filtrage par domaine
        /// (cosmétiques `##`, chemins d'URL, options `$script`, etc.).
        public var unsupported = 0
        /// Lignes illisibles ou noms de domaine invalides.
        public var invalid = 0
        public init() {}
    }

    public init() {}

    public mutating func merge(_ other: ParsedBlocklist) {
        blocked.formUnion(other.blocked)
        allowed.formUnion(other.allowed)
        stats.lines += other.stats.lines
        stats.comments += other.stats.comments
        stats.unsupported += other.stats.unsupported
        stats.invalid += other.stats.invalid
    }
}

/// Lit les formats de listes courants et n'en garde que le blocage par domaine,
/// le seul qui fonctionne en HTTPS sans interception TLS.
///
/// Le format est détecté ligne par ligne, ce qui permet de lire indifféremment :
/// - Adblock Plus / uBlock / AdGuard : `||domaine^`, `@@||domaine^`, `! commentaire`
/// - fichiers hosts : `0.0.0.0 domaine [domaine…]  # commentaire`
/// - listes de domaines : `domaine` (UT1, HaGeZi « onlydomains », etc.)
public enum BlocklistParser {

    public static func parse(_ data: Data) -> ParsedBlocklist {
        var result = ParsedBlocklist()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            let n = bytes.count
            while start < n {
                var end = start
                while end < n && bytes[end] != 0x0A { end += 1 }
                parseLine(bytes[start..<end], into: &result)
                start = end + 1
            }
        }
        return result
    }

    public static func parse(_ text: String) -> ParsedBlocklist {
        parse(Data(text.utf8))
    }

    // MARK: - Ligne

    private static func parseLine(_ rawLine: Slice<UnsafeBufferPointer<UInt8>>, into r: inout ParsedBlocklist) {
        r.stats.lines += 1
        var line = rawLine.trimmed()
        // BOM UTF-8 éventuel en tête de fichier
        if line.count >= 3, line[line.startIndex] == 0xEF, line[line.startIndex + 1] == 0xBB, line[line.startIndex + 2] == 0xBF {
            line = line.dropFirst(3).trimmed()
        }
        guard let first = line.first else { return }

        switch first {
        case UInt8(ascii: "!"), UInt8(ascii: "["):
            r.stats.comments += 1
            return
        case UInt8(ascii: "#"):
            // `##sélecteur` est une règle cosmétique, le reste un commentaire.
            if line.starts(with: "##".utf8) { r.stats.unsupported += 1 } else { r.stats.comments += 1 }
            return
        default:
            break
        }

        if line.starts(with: "@@".utf8) {
            switch parseAdblockRule(line.dropFirst(2)) {
            case .domain(let d): r.allowed.insert(d)
            case .unsupported: r.stats.unsupported += 1
            case .invalid: r.stats.invalid += 1
            }
            return
        }
        if line.starts(with: "||".utf8) || line.starts(with: "|".utf8) {
            switch parseAdblockRule(line) {
            case .domain(let d): r.blocked.insert(d)
            case .unsupported: r.stats.unsupported += 1
            case .invalid: r.stats.invalid += 1
            }
            return
        }
        if line.containsSequence("##") || line.containsSequence("#@#") || line.containsSequence("#?#") || line.containsSequence("#$#") {
            r.stats.unsupported += 1
            return
        }

        // Retire un commentaire en fin de ligne (`domaine # commentaire`).
        if let hash = line.firstIndex(of: UInt8(ascii: "#")) {
            line = line[line.startIndex..<hash].trimmed()
        }
        let tokens = line.split(whereSeparator: { $0 == 0x20 || $0 == 0x09 })
        guard let head = tokens.first else { return }

        if tokens.count >= 2, isHostsAddress(head) {
            for token in tokens.dropFirst() {
                if isReservedHostsName(token) { continue }
                if let d = DomainName.normalize(token) { r.blocked.insert(d) } else { r.stats.invalid += 1 }
            }
            return
        }
        if tokens.count == 1 {
            if head.contains(UInt8(ascii: "/")) || head.contains(UInt8(ascii: "$")) || head.contains(UInt8(ascii: "^")) {
                r.stats.unsupported += 1   // règle d'URL ou syntaxe adblock sans `||`
            } else if isReservedHostsName(head) || isHostsAddress(head) && !DomainName.isIPv4(head) {
                r.stats.invalid += 1
            } else if let d = DomainName.normalize(head) {
                r.blocked.insert(d)
            } else {
                r.stats.invalid += 1
            }
            return
        }
        r.stats.invalid += 1
    }

    // MARK: - Règles Adblock

    private enum RuleResult { case domain(String), unsupported, invalid }

    /// Options qui ne restreignent pas le blocage : la règle bloque bien tout le domaine.
    private static let neutralOptions: Set<String> = ["important", "all", "document", "doc", "popup"]

    private static func parseAdblockRule(_ rule: Slice<UnsafeBufferPointer<UInt8>>) -> RuleResult {
        // Seul `||domaine` est un blocage de domaine ; `|http://…` est une règle d'URL.
        guard rule.starts(with: "||".utf8) else { return .unsupported }
        var body = rule.dropFirst(2)
        var options: Slice<UnsafeBufferPointer<UInt8>>? = nil
        if let dollar = body.firstIndex(of: UInt8(ascii: "$")) {
            options = body[(dollar + 1)...]
            body = body[body.startIndex..<dollar]
        }
        // Fin de domaine autorisée : rien, `^` ou `^|`.
        if body.last == UInt8(ascii: "|") { body = body.dropLast() }
        if body.last == UInt8(ascii: "^") { body = body.dropLast() }
        if body.isEmpty { return .invalid }
        if body.contains(where: { $0 == UInt8(ascii: "/") || $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "^") || $0 == UInt8(ascii: "|") || $0 == UInt8(ascii: ":") }) {
            return .unsupported
        }
        if let options {
            for opt in options.split(separator: UInt8(ascii: ",")) {
                let name = String(decoding: opt, as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
                if !neutralOptions.contains(name) { return .unsupported }
            }
        }
        guard let d = DomainName.normalize(body) else { return .invalid }
        return .domain(d)
    }

    // MARK: - Hosts

    private static func isHostsAddress(_ token: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        if DomainName.isIPv4(token) { return true }
        // IPv6 (`::`, `::1`, `fe80::…`) : contient `:` et seulement des chiffres hexadécimaux.
        guard token.contains(UInt8(ascii: ":")) else { return false }
        return token.allSatisfy { b in
            b == UInt8(ascii: ":") || b == UInt8(ascii: ".") || (b >= 0x30 && b <= 0x39) || (b | 0x20 >= 0x61 && b | 0x20 <= 0x66)
        }
    }

    private static let reservedHostsNames: Set<String> = [
        "localhost", "localhost.localdomain", "local", "broadcasthost", "ip6-localhost",
        "ip6-loopback", "ip6-localnet", "ip6-mcastprefix", "ip6-allnodes", "ip6-allrouters",
        "ip6-allhosts", "0.0.0.0",
    ]

    private static func isReservedHostsName(_ token: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        token.count <= 21 && reservedHostsNames.contains(String(decoding: token, as: UTF8.self).lowercased())
    }
}

// MARK: - Aides sur les octets

extension Slice where Base == UnsafeBufferPointer<UInt8> {
    func trimmed() -> Slice<Base> {
        var s = startIndex, e = endIndex
        while s < e, Self.isSpace(base[s]) { s += 1 }
        while e > s, Self.isSpace(base[e - 1]) { e -= 1 }
        return base[s..<e]
    }

    func containsSequence(_ needle: String) -> Bool {
        let n = Array(needle.utf8)
        guard count >= n.count else { return false }
        var i = startIndex
        while i <= endIndex - n.count {
            if base[i] == n[0] {
                var j = 1
                while j < n.count && base[i + j] == n[j] { j += 1 }
                if j == n.count { return true }
            }
            i += 1
        }
        return false
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
}
