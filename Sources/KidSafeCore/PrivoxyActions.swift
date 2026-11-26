import Foundation

/// Génère les fichiers `.action` Privoxy de Yamoxy.
///
/// Tous les motifs sont des motifs d'hôte : `.exemple.com` bloque `exemple.com`
/// et tous ses sous-domaines, en HTTP comme en HTTPS (requêtes CONNECT).
public enum PrivoxyActions {

    public static let filePrefix = "yamoxy-"
    /// Préfixe des fichiers écrits par KidSafe (ancien nom), repris ou supprimés par Yamoxy.
    public static let legacyFilePrefix = "kidsafe-"
    public static let allowFileName = "yamoxy-allow.action"
    public static let strictFileName = "yamoxy-strict.action"
    /// Début du motif de blocage, affiché par Privoxy (page « Request blocked ») et lu par le message « site bloqué ».
    public static let reasonPrefix = "+block{Yamoxy : "
    static let legacyReasonPrefix = "+block{KidSafe : "

    /// Fichier écrit par KidSafe, réécrit aux couleurs de Yamoxy (en-têtes et motifs de blocage).
    static func rebrand(_ text: String) -> String {
        text.replacingOccurrences(of: legacyReasonPrefix, with: reasonPrefix)
            .replacingOccurrences(of: "# KidSafe — ", with: "# Yamoxy — ")
    }

    public static func fileName(forCategory id: String) -> String {
        filePrefix + "cat-" + sanitizeID(id) + ".action"
    }

    /// Fichier d'une catégorie : un bloc `+block`, puis les exceptions propres aux listes.
    public static func categoryFile(id: String, title: String, sources: [String],
                                    list: ParsedBlocklist, date: Date = Date()) -> String {
        let blocked = DomainName.compact(list.blocked)
        // Une exception n'a de sens que si elle lève un blocage de cette catégorie.
        let allowed = DomainName.compact(list.allowed.filter { DomainName.isCovered($0, by: list.blocked) })
        var out = header(title: L("action.header.category", title, id), date: date,
                         extra: [L("action.header.counts", blocked.count, allowed.count)]
                            + sources.map { L("action.header.source", $0) })
        out.reserveCapacity(out.utf8.count + blocked.count * 24)
        out += "{ +block{Yamoxy : \(escapeReason(title))} }\n"
        for d in blocked { out += pattern(d); out += "\n" }
        if !allowed.isEmpty {
            out += "\n{ -block }\n"
            for d in allowed { out += pattern(d); out += "\n" }
        }
        return out
    }

    /// Mode strict (liste blanche) : tout est bloqué sauf ce que lève `yamoxy-allow.action`.
    public static func strictFile(date: Date = Date()) -> String {
        header(title: L("action.header.strict"), date: date, extra: [])
            + "{ +block{Yamoxy : \(escapeReason(L("action.reason.strict")))} }\n/\n"
    }

    public static let customBlockFileName = "yamoxy-block.action"
    public static let servicesFileName = "yamoxy-services.action"

    /// Domaines bloqués à la main par le parent.
    public static func customBlockFile(domains: [String], date: Date = Date()) -> String {
        let valid = DomainName.compact(Set(domains.compactMap(DomainName.normalize)))
        var out = header(title: L("action.header.custom"), date: date, extra: [L("action.header.customCount", valid.count)])
        if !valid.isEmpty {
            out += "{ +block{Yamoxy : \(escapeReason(L("action.reason.custom")))} }\n"
            for d in valid { out += pattern(d); out += "\n" }
        }
        return out
    }

    /// Réseaux sociaux bloqués à cet instant (réécrit à chaque changement de plage horaire).
    /// L'en-tête ne contient pas de date : le fichier ne change que si la liste bloquée change.
    public static func servicesFile(blocked: [SocialService]) -> String {
        var out = "# Yamoxy — " + L("action.header.services") + "\n"
        out += "# " + L("action.header.servicesNote") + "\n\n"
        for s in blocked {
            out += "{ +block{Yamoxy : \(escapeReason(s.name))} }\n"
            for d in DomainName.compact(Set(s.domains.compactMap(DomainName.normalize))) { out += pattern(d); out += "\n" }
            out += "\n"
        }
        return out
    }

    /// Liste blanche du parent : chargée en dernier, elle l'emporte sur toutes les catégories.
    public static func allowFile(domains: [String], date: Date = Date()) -> String {
        let valid = DomainName.compact(Set(domains.compactMap(DomainName.normalize)))
        var out = header(title: L("action.header.allow"), date: date, extra: [L("action.header.allowCount", valid.count)])
        out += "{ -block }\n"
        for d in valid { out += pattern(d); out += "\n" }
        return out
    }

    // MARK: -

    static func pattern(_ d: String) -> String {
        DomainName.isIPv4(d) ? d : "." + d
    }

    private static func header(title: String, date: Date, extra: [String]) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var lines = ["# Yamoxy — \(title)",
                     "# " + L("action.header.generated", stamp)]
        lines += extra.map { "# " + $0.replacingOccurrences(of: "\n", with: " ") }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Le motif de blocage est affiché sur la page d'erreur de Privoxy ; `{` et `}` y sont interdits.
    private static func escapeReason(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func sanitizeID(_ id: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_")
        let s = String(id.lowercased().map { allowed.contains($0) ? $0 : "-" })
        return s.isEmpty ? "sans-nom" : s
    }
}
