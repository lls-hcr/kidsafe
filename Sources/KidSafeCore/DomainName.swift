import Foundation

/// Normalisation et validation des noms d'hôte.
public enum DomainName {

    /// Renvoie le nom normalisé (minuscules, sans `*.` ni point initial/final),
    /// ou `nil` s'il n'est pas un nom d'hôte valide d'au moins deux labels ou une IPv4.
    public static func normalize<S: Collection>(_ raw: S) -> String? where S.Element == UInt8 {
        var bytes = Array(raw)
        // Préfixes de joker courants : `*.exemple.com`, `.exemple.com`
        if bytes.starts(with: [UInt8(ascii: "*"), UInt8(ascii: ".")]) { bytes.removeFirst(2) }
        while bytes.first == UInt8(ascii: ".") { bytes.removeFirst() }
        while bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.count <= 253 else { return nil }

        for i in bytes.indices where bytes[i] >= 0x41 && bytes[i] <= 0x5A { bytes[i] |= 0x20 }
        if isIPv4(bytes) { return String(decoding: bytes, as: UTF8.self) }

        var labels = 0
        var labelStart = 0
        var lastLabelAllDigits = true
        for i in 0...bytes.count {
            if i == bytes.count || bytes[i] == UInt8(ascii: ".") {
                let len = i - labelStart
                guard len >= 1, len <= 63 else { return nil }
                guard bytes[labelStart] != UInt8(ascii: "-"), bytes[i - 1] != UInt8(ascii: "-") else { return nil }
                labels += 1
                if i == bytes.count {
                    lastLabelAllDigits = bytes[labelStart..<i].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                }
                labelStart = i + 1
                continue
            }
            let b = bytes[i]
            let ok = (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
            guard ok else { return nil }   // espaces, `/`, `*`, non-ASCII (IDN non punycodé)…
        }
        guard labels >= 2, !lastLabelAllDigits else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func normalize(_ raw: String) -> String? { normalize(Array(raw.utf8)) }

    public static func isIPv4<S: Collection>(_ s: S) -> Bool where S.Element == UInt8 {
        var parts = 0, digits = 0, value = 0
        for b in s {
            if b == UInt8(ascii: ".") {
                guard digits > 0 else { return false }
                parts += 1; digits = 0; value = 0
            } else if b >= 0x30 && b <= 0x39 {
                digits += 1; value = value * 10 + Int(b - 0x30)
                guard digits <= 3, value <= 255 else { return false }
            } else {
                return false
            }
        }
        return digits > 0 && parts == 3
    }

    public static func isIPv4(_ s: String) -> Bool { isIPv4(Array(s.utf8)) }

    /// Supprime les domaines déjà couverts par un domaine parent présent dans l'ensemble :
    /// dans Privoxy, `.exemple.com` couvre aussi `www.exemple.com`.
    public static func compact(_ domains: Set<String>) -> [String] {
        var keyed: [(key: String, domain: String)] = []
        keyed.reserveCapacity(domains.count)
        for d in domains where isIPv4(d) || !hasBlockedParent(d, in: domains) {
            keyed.append((isIPv4(d) ? "~" + d : sortKey(d), d))
        }
        keyed.sort { $0.key < $1.key }
        return keyed.map(\.domain)
    }

    /// Vrai si `domain` ou l'un de ses parents est dans `set`.
    public static func isCovered(_ domain: String, by set: Set<String>) -> Bool {
        set.contains(domain) || hasBlockedParent(domain, in: set)
    }

    private static func hasBlockedParent(_ d: String, in set: Set<String>) -> Bool {
        var rest = Substring(d)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            guard rest.contains(".") else { return false }   // on ne bloque jamais un TLD seul
            if set.contains(String(rest)) { return true }
        }
        return false
    }

    /// Tri par labels inversés (`com.exemple.www`) : les sous-domaines d'un même site restent groupés.
    /// Les IPv4 sont placées à la fin (`~` est après les lettres en ASCII).
    private static func sortKey(_ d: String) -> String {
        d.split(separator: ".").reversed().joined(separator: "\u{1}")
    }
}
