import Foundation

/// Emplacements des fichiers de KidSafe.
public struct KidSafePaths: Sendable {
    public var supportDir: URL
    public var catalogFile: URL { supportDir.appendingPathComponent("catalog.json") }
    public var statusFile: URL { supportDir.appendingPathComponent("status.json") }
    /// Copies des listes importées depuis le disque.
    public var listsDir: URL { supportDir.appendingPathComponent("lists", isDirectory: true) }
    public var cacheDir: URL { supportDir.appendingPathComponent("cache", isDirectory: true) }

    public init(supportDir: URL) { self.supportDir = supportDir }

    /// `~/Library/Application Support/KidSafe` pour l'instant ; le helper root utilisera
    /// `/Library/Application Support/KidSafe`, que l'enfant ne peut pas modifier.
    public static var user: KidSafePaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KidSafePaths(supportDir: base.appendingPathComponent("KidSafe", isDirectory: true))
    }
}

/// État de la dernière application des listes, affiché par l'app.
public struct KidSafeStatus: Codable, Sendable, Equatable {
    public var lastApplied: Date?
    public var domainCounts: [String: Int] = [:]
    public var failures: [String: String] = [:]
    public var warnings: [String: [String]] = [:]
    /// État de chaque liste cochée lors de la dernière mise à jour (clé : identifiant de la catégorie).
    public var lists: [String: ListStatus] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case lastApplied, domainCounts, failures, warnings, lists }

    /// Les champs ajoutés après la première version sont facultatifs dans le fichier.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastApplied = try c.decodeIfPresent(Date.self, forKey: .lastApplied)
        domainCounts = try c.decodeIfPresent([String: Int].self, forKey: .domainCounts) ?? [:]
        failures = try c.decodeIfPresent([String: String].self, forKey: .failures) ?? [:]
        warnings = try c.decodeIfPresent([String: [String]].self, forKey: .warnings) ?? [:]
        lists = try c.decodeIfPresent([String: ListStatus].self, forKey: .lists) ?? [:]
    }

    /// Résumé de la dernière mise à jour des listes cochées.
    public struct Summary: Equatable, Sendable {
        public var checked = 0, updated = 0, unchanged = 0, failed = 0
    }

    public func summary(for ids: [String]) -> Summary? {
        guard lastApplied != nil else { return nil }
        var s = Summary()
        for id in ids {
            if failures[id] != nil || lists[id]?.cacheUsed != nil { s.failed += 1; continue }
            guard let l = lists[id] else { continue }
            s.checked += 1
            if l.changedNow { s.updated += 1 } else { s.unchanged += 1 }
        }
        return s.checked + s.failed > 0 ? s : nil
    }
}

/// État d'une liste après une mise à jour.
public struct ListStatus: Codable, Sendable, Equatable {
    /// Dernière vérification en ligne réussie.
    public var checked: Date?
    /// Dernier changement du contenu.
    public var changed: Date?
    /// Le contenu a changé lors de cette mise à jour.
    public var changedNow = false
    /// Variation du nombre de domaines lors de cette mise à jour (nil : première fois).
    public var delta: Int?
    /// Téléchargement impossible : date de la copie utilisée à la place.
    public var cacheUsed: Date?
    /// Raison de l'échec, si elle est connue.
    public var error: String?
    public init(checked: Date? = nil, changed: Date? = nil, changedNow: Bool = false, delta: Int? = nil,
                cacheUsed: Date? = nil, error: String? = nil) {
        self.checked = checked; self.changed = changed; self.changedNow = changedNow; self.delta = delta
        self.cacheUsed = cacheUsed; self.error = error
    }
}

/// Étape en cours pour une liste, affichée pendant la mise à jour.
public enum ListProgress: Sendable, Equatable {
    case downloading(received: Int64, expected: Int64)
    case converting
    case installing
}

/// Importe une liste depuis le disque : elle est vérifiée puis copiée dans `listsDir`,
/// pour rester disponible même si le fichier d'origine est déplacé ou supprimé.
public enum LocalListImporter {
    public enum ImportError: Error, CustomStringConvertible {
        case unreadable(String), noDomains(String), tooLarge(String)
        public var description: String {
            switch self {
            case .unreadable(let p): return L("error.localUnreadable", p)
            case .noDomains(let p): return L("error.localNoDomains", p)
            case .tooLarge(let p): return L("error.tooLarge", p)
            }
        }
    }

    public static let maxBytes = 512 * 1024 * 1024

    public static func importFile(_ src: URL, id: String, into listsDir: URL) throws -> (source: Catalog.Source, domains: Int) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        if let size = attrs?[.size] as? Int, size > maxBytes { throw ImportError.tooLarge(src.lastPathComponent) }
        guard let data = FileManager.default.contents(atPath: src.path) else { throw ImportError.unreadable(src.path) }
        let parsed = BlocklistParser.parse(data)
        guard !parsed.blocked.isEmpty else { throw ImportError.noDomains(src.lastPathComponent) }

        try FileManager.default.createDirectory(at: listsDir, withIntermediateDirectories: true)
        let dest = listsDir.appendingPathComponent(PrivoxyActions.sanitizeID(id) + ".txt")
        try data.write(to: dest, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        return (Catalog.Source(url: dest.absoluteString, license: src.lastPathComponent), parsed.blocked.count)
    }
}

public extension Catalog {
    /// Ajoute une liste depuis un fichier local (copie vérifiée dans `listsDir`). Renvoie le nombre de domaines.
    @discardableResult
    mutating func addLocalList(file: URL, id: String, name: String, listsDir: URL) throws -> Int {
        let clean = PrivoxyActions.sanitizeID(id)
        guard !categories.contains(where: { PrivoxyActions.sanitizeID($0.id) == clean }) else { throw EditError.duplicateID(clean) }
        let imported = try LocalListImporter.importFile(file, id: clean, into: listsDir)
        try addCustomList(id: clean, name: name, sources: [imported.source])
        return imported.domains
    }

    /// Identifiant libre dérivé d'un nom (`Ma liste` → `ma-liste`, `ma-liste-2`…).
    func uniqueID(for name: String) -> String {
        let base = PrivoxyActions.sanitizeID(name.folding(options: .diacriticInsensitive, locale: nil))
        var id = base, n = 2
        while categories.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        return id
    }
}

/// Opérations de haut niveau partagées par l'app et la CLI.
public struct KidSafeEngine: Sendable {
    public var paths: KidSafePaths
    public init(paths: KidSafePaths = .user) { self.paths = paths }

    /// Charge le catalogue ; à la première utilisation, enregistre le catalogue par défaut.
    public func loadCatalog() throws -> Catalog {
        if FileManager.default.fileExists(atPath: paths.catalogFile.path) {
            return try Catalog.load(from: paths.catalogFile)
        }
        try save(Catalog.default)
        return Catalog.default
    }

    public func save(_ catalog: Catalog) throws {
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try catalog.save(to: paths.catalogFile)
    }

    public func loadStatus() -> KidSafeStatus {
        guard let data = try? Data(contentsOf: paths.statusFile) else { return KidSafeStatus() }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(KidSafeStatus.self, from: data)) ?? KidSafeStatus()
    }

    /// Supprime une liste perso et, si elle venait du disque, sa copie locale.
    public func removeCustomList(_ id: String, from catalog: inout Catalog) throws {
        let sources = catalog.categories.first { $0.id == id }?.sources ?? []
        try catalog.removeCustomList(id)
        for s in sources {
            guard let url = URL(string: s.url), url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(paths.listsDir.standardizedFileURL.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public struct ApplyResult: Sendable {
        public var update: BlocklistUpdater.Result
        public var install: PrivoxyInstaller.Report
        public var status: KidSafeStatus
    }

    /// Met le filtrage en pause (aucun téléchargement) ; la reprise passe par `apply`.
    public func pause(_ catalog: Catalog, installer: PrivoxyInstaller) throws {
        try installer.pause(options: PrivoxyConfigEditor.Options(catalog: catalog))
    }

    /// À appeler chaque minute : met à jour les réseaux sociaux bloqués selon les plages horaires.
    /// Renvoie vrai si le fichier a changé. Sans effet tant que le filtrage est en pause.
    @discardableResult
    public func refreshServices(_ catalog: Catalog, installer: PrivoxyInstaller, date: Date = Date()) throws -> Bool {
        guard catalog.filteringEnabled, !installer.isPaused() else { return false }
        return try installer.refreshFile(PrivoxyActions.servicesFileName,
                                         content: PrivoxyActions.servicesFile(blocked: catalog.blockedServices(at: date)))
    }

    /// Télécharge, convertit et installe les listes cochées, puis enregistre l'état.
    /// `progress` : étape de chaque liste (téléchargement, conversion, remplacement dans Privoxy).
    public func apply(_ catalog: Catalog, installer: PrivoxyInstaller, date: Date = Date(),
                      progress: (@Sendable (String, ListProgress) -> Void)? = nil) async throws -> ApplyResult {
        let previous = loadStatus()
        let updater = BlocklistUpdater(fetcher: SourceFetcher(cacheDir: paths.cacheDir))
        let prepared = await updater.prepare(catalog, existingConfDir: installer.confDir, date: date, progress: progress)
        for c in prepared.categories { progress?(c.id, .installing) }
        for f in prepared.failed { progress?(f.id, .installing) }
        let report = try installer.install(prepared.plan)

        var status = KidSafeStatus()
        status.lastApplied = Date()
        for c in prepared.categories {
            status.domainCounts[c.id] = c.blockedCount
            if !c.warnings.isEmpty { status.warnings[c.id] = c.warnings }
            var l = c.list
            l.delta = previous.domainCounts[c.id].map { c.blockedCount - $0 }
            if l.cacheUsed != nil, l.checked == nil { l.checked = previous.lists[c.id]?.checked }
            status.lists[c.id] = l
        }
        for f in prepared.failed {
            status.failures[f.id] = f.error
            // Liste précédente conservée : même nombre de domaines, date de la dernière vérification réussie.
            if let n = previous.domainCounts[f.id], f.error.contains(L("warning.previousKept")) {
                status.domainCounts[f.id] = n
                status.lists[f.id] = ListStatus(checked: previous.lists[f.id]?.checked, changed: previous.lists[f.id]?.changed,
                                                cacheUsed: previous.lists[f.id]?.checked ?? previous.lastApplied, error: f.error)
            }
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try? enc.encode(status).write(to: paths.statusFile, options: .atomic)
        return ApplyResult(update: prepared, install: report, status: status)
    }
}
