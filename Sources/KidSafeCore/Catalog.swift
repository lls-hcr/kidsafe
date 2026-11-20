import Foundation

/// Réglages de KidSafe : catégories cochées, sources de chaque catégorie, liste blanche.
/// C'est le fichier que l'interface de l'app modifiera.
public struct Catalog: Codable, Sendable, Equatable {
    public var categories: [Category]
    /// Domaines toujours autorisés (l'emportent sur toutes les catégories).
    public var allowlist: [String]
    /// Mode strict : tout est bloqué sauf la liste blanche.
    public var strictMode: Bool
    /// Désactive les moyens de couper Privoxy depuis le navigateur.
    public var hardenPrivoxy: Bool
    /// Domaines bloqués à la main par le parent.
    public var blockedDomains: [String]
    /// Règle de chaque réseau social (clé : `SocialService.id`) ; absent = autorisé.
    public var services: [String: ServicePolicy]
    /// Interrupteur général : faux = Privoxy laisse tout passer (les listes restent installées).
    public var filteringEnabled: Bool
    /// Mise à jour automatique des listes, en heures ; 0 = jamais.
    public var refreshHours: Int
    /// Mot de passe parent facultatif.
    public var parentPassword: PasswordHash?

    public static let refreshChoices = [0, 1, 6, 12, 24, 72, 168]

    public init(categories: [Category], allowlist: [String] = [], strictMode: Bool = false, hardenPrivoxy: Bool = true,
                blockedDomains: [String] = [], services: [String: ServicePolicy] = [:], filteringEnabled: Bool = true,
                refreshHours: Int = 24, parentPassword: PasswordHash? = nil) {
        self.categories = categories
        self.allowlist = allowlist
        self.strictMode = strictMode
        self.hardenPrivoxy = hardenPrivoxy
        self.blockedDomains = blockedDomains
        self.services = services
        self.filteringEnabled = filteringEnabled
        self.refreshHours = refreshHours
        self.parentPassword = parentPassword
    }

    private enum CodingKeys: String, CodingKey {
        case categories, allowlist, strictMode, hardenPrivoxy, blockedDomains, services, filteringEnabled, refreshHours, parentPassword
    }

    /// Les champs ajoutés après la première version sont facultatifs dans le fichier.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(categories: try c.decode([Category].self, forKey: .categories),
                  allowlist: try c.decodeIfPresent([String].self, forKey: .allowlist) ?? [],
                  strictMode: try c.decodeIfPresent(Bool.self, forKey: .strictMode) ?? false,
                  hardenPrivoxy: try c.decodeIfPresent(Bool.self, forKey: .hardenPrivoxy) ?? true,
                  blockedDomains: try c.decodeIfPresent([String].self, forKey: .blockedDomains) ?? [],
                  services: try c.decodeIfPresent([String: ServicePolicy].self, forKey: .services) ?? [:],
                  filteringEnabled: try c.decodeIfPresent(Bool.self, forKey: .filteringEnabled) ?? true,
                  refreshHours: try c.decodeIfPresent(Int.self, forKey: .refreshHours) ?? 24,
                  parentPassword: try c.decodeIfPresent(PasswordHash.self, forKey: .parentPassword))
    }

    public func policy(for serviceID: String) -> ServicePolicy { services[serviceID] ?? ServicePolicy() }

    /// Réseaux sociaux à bloquer à cet instant.
    public func blockedServices(at date: Date, calendar: Calendar = .current) -> [SocialService] {
        SocialService.all.filter { policy(for: $0.id).isBlocked(at: date, calendar: calendar) }
    }

    /// Nettoie une saisie (`https://www.Exemple.com/page` → `www.exemple.com`).
    public static func normalizeUserDomain(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.split(whereSeparator: { "/?#".contains($0) }).first ?? "")
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy(\.isNumber) { s = String(s[..<colon]) }
        return DomainName.normalize(s)
    }

    public enum DomainError: Error, CustomStringConvertible {
        case invalid(String)
        public var description: String { switch self { case .invalid(let d): return L("app.allow.invalid", d) } }
    }

    /// Bloque un domaine ; il est retiré de la liste blanche s'il y figurait.
    @discardableResult
    public mutating func addBlockedDomain(_ raw: String) throws -> String {
        guard let d = Self.normalizeUserDomain(raw) else { throw DomainError.invalid(raw) }
        allowlist.removeAll { $0 == d }
        if !blockedDomains.contains(d) { blockedDomains.append(d); blockedDomains.sort() }
        return d
    }

    /// Autorise un domaine ; il est retiré des domaines bloqués s'il y figurait.
    @discardableResult
    public mutating func addAllowedDomain(_ raw: String) throws -> String {
        guard let d = Self.normalizeUserDomain(raw) else { throw DomainError.invalid(raw) }
        blockedDomains.removeAll { $0 == d }
        if !allowlist.contains(d) { allowlist.append(d); allowlist.sort() }
        return d
    }

    public struct Category: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var enabled: Bool
        public var sources: [Source]
        /// Avertissement à afficher avant d'activer la catégorie (ex. liste très lourde).
        public var warning: String?
        /// Vrai pour une liste ajoutée par le parent (supprimable depuis l'interface).
        public var custom: Bool?

        /// Nom affiché : traduit pour les catégories du catalogue par défaut, tel quel pour les listes perso.
        public var displayName: String {
            guard custom != true else { return name }
            let key = "category." + id
            let value = L(key)
            return value == key ? name : value
        }

        /// Avertissement traduit (clé de traduction ou texte libre).
        public var displayWarning: String? {
            guard let warning else { return nil }
            let value = L(warning)
            return value
        }
        public init(id: String, name: String, enabled: Bool, sources: [Source], warning: String? = nil, custom: Bool? = nil) {
            self.id = id; self.name = name; self.enabled = enabled; self.sources = sources
            self.warning = warning; self.custom = custom
        }
    }

    /// Au-delà de ce nombre de domaines, Privoxy consomme beaucoup de mémoire
    /// (mesuré : 4,6 M domaines ≈ 790 Mo, +70 ms par requête, ~4 s de rechargement).
    public static let heavyListThreshold = 1_000_000

    public enum EditError: Error, CustomStringConvertible {
        case duplicateID(String), unknownID(String), notCustom(String)
        public var description: String {
            switch self {
            case .duplicateID(let id): return L("error.duplicateID", id)
            case .unknownID(let id): return L("error.unknownID", id)
            case .notCustom(let id): return L("error.notCustom", id)
            }
        }
    }

    /// Ajoute une liste personnalisée, activée. Le téléchargement et l'installation
    /// se font au prochain `update`.
    public mutating func addCustomList(id: String, name: String, sources: [Source], warning: String? = nil) throws {
        let clean = PrivoxyActions.sanitizeID(id)
        guard !categories.contains(where: { PrivoxyActions.sanitizeID($0.id) == clean }) else { throw EditError.duplicateID(clean) }
        categories.append(Category(id: clean, name: name, enabled: true, sources: sources, warning: warning, custom: true))
    }

    public mutating func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { throw EditError.unknownID(id) }
        categories[i].enabled = enabled
    }

    public mutating func removeCustomList(_ id: String) throws {
        guard let i = categories.firstIndex(where: { $0.id == id }) else { throw EditError.unknownID(id) }
        guard categories[i].custom == true else { throw EditError.notCustom(id) }
        categories.remove(at: i)
    }

    public struct Source: Codable, Sendable, Equatable {
        /// `https://…` ou `file://…`. Formats acceptés : texte brut, `.gz`, `.tar.gz`/`.tgz`.
        public var url: String
        /// Pour une archive tar : chemin du fichier à lire (ex. `adult/domains` pour l'UT1).
        public var archiveMember: String?
        public var license: String?
        public init(url: String, archiveMember: String? = nil, license: String? = nil) {
            self.url = url; self.archiveMember = archiveMember; self.license = license
        }
    }

    public static func load(from url: URL) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}
