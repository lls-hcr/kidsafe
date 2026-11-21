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
    public init() {}
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
    public func apply(_ catalog: Catalog, installer: PrivoxyInstaller, date: Date = Date()) async throws -> ApplyResult {
        let updater = BlocklistUpdater(fetcher: SourceFetcher(cacheDir: paths.cacheDir))
        let prepared = await updater.prepare(catalog, existingConfDir: installer.confDir, date: date)
        let report = try installer.install(prepared.plan)

        var status = KidSafeStatus()
        status.lastApplied = Date()
        for c in prepared.categories {
            status.domainCounts[c.id] = c.blockedCount
            if !c.warnings.isEmpty { status.warnings[c.id] = c.warnings }
        }
        for f in prepared.failed { status.failures[f.id] = f.error }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        try? enc.encode(status).write(to: paths.statusFile, options: .atomic)
        return ApplyResult(update: prepared, install: report, status: status)
    }
}
