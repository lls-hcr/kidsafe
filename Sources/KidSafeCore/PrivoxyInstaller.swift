import Foundation

/// Installe les fichiers KidSafe dans le dossier de configuration de Privoxy,
/// teste la configuration et revient en arrière si Privoxy la refuse.
///
/// Privoxy relit tout seul les fichiers `.action` et `config` modifiés :
/// aucun redémarrage n'est nécessaire.
public struct PrivoxyInstaller: Sendable {
    public var confDir: URL
    public var configFile: URL
    /// Binaire Privoxy utilisé pour `--config-test`. `nil` : pas de test.
    public var privoxyBinary: URL?

    public init(confDir: URL, configFile: URL? = nil, privoxyBinary: URL? = nil) {
        self.confDir = confDir
        self.configFile = configFile ?? confDir.appendingPathComponent("config")
        self.privoxyBinary = privoxyBinary
    }

    /// Privoxy intégré de KidSafe s'il est installé, sinon un Privoxy existant (Homebrew…).
    public static func detect() -> PrivoxyInstaller? {
        let dir = BundledPrivoxy.installDir(supportDir: KidSafePaths.user.supportDir)
        let bin = dir.appendingPathComponent("bin/privoxy")
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("config").path),
           FileManager.default.isExecutableFile(atPath: bin.path) {
            return PrivoxyInstaller(confDir: dir, privoxyBinary: bin)
        }
        return detectExternal()
    }

    /// Emplacements habituels sur macOS (installeur officiel, Homebrew Apple Silicon et Intel).
    public static func detectExternal() -> PrivoxyInstaller? {
        let fm = FileManager.default
        let candidates: [(conf: String, bin: String)] = [
            ("/usr/local/etc/privoxy", "/usr/local/sbin/privoxy"),
            ("/opt/homebrew/etc/privoxy", "/opt/homebrew/sbin/privoxy"),
            ("/Applications/Privoxy/", "/Applications/Privoxy/privoxy"),
        ]
        for c in candidates where fm.fileExists(atPath: c.conf + "/config") {
            let bin = fm.isExecutableFile(atPath: c.bin) ? URL(fileURLWithPath: c.bin) : nil
            return PrivoxyInstaller(confDir: URL(fileURLWithPath: c.conf), privoxyBinary: bin)
        }
        return nil
    }

    public struct Plan: Sendable {
        /// Fichiers à écrire (nom → contenu), dans l'ordre de chargement.
        public var files: [(name: String, content: String)]
        public var options: PrivoxyConfigEditor.Options
        public init(files: [(name: String, content: String)], options: PrivoxyConfigEditor.Options) {
            self.files = files; self.options = options
        }
    }

    public struct Report: Sendable {
        public var written: [String] = []
        public var removed: [String] = []
        public var configChanged = false
        public var configTested = false
    }

    public func install(_ plan: Plan) throws -> Report {
        let fm = FileManager.default
        let oldConfig = try String(contentsOf: configFile, encoding: .utf8)
        let newConfig = PrivoxyConfigEditor.apply(actionFiles: plan.files.map(\.name), to: oldConfig, options: plan.options)
        let wanted = Set(plan.files.map(\.name))
        let stale = try existingKidSafeFiles().filter { !wanted.contains($0) }

        // Sauvegarde de tout ce qui va changer, pour pouvoir revenir en arrière.
        let backup = confDir.appendingPathComponent(".kidsafe-backup", isDirectory: true)
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: backup) }
        var previouslyExisting: Set<String> = []
        for name in Set(plan.files.map(\.name)).union(stale) {
            let src = confDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: backup.appendingPathComponent(name))
                previouslyExisting.insert(name)
            }
        }

        var report = Report()
        do {
            for f in plan.files {
                try writeAtomically(f.content, to: confDir.appendingPathComponent(f.name))
                report.written.append(f.name)
            }
            if newConfig != oldConfig {
                try writeAtomically(newConfig, to: configFile, keepAttributesOf: configFile)
                report.configChanged = true
            }
            if let bin = privoxyBinary {
                try configTest(binary: bin)
                report.configTested = true
            }
        } catch {
            // Retour arrière : config d'origine, fichiers d'origine, suppression des nouveaux.
            try? writeAtomically(oldConfig, to: configFile, keepAttributesOf: configFile)
            for f in plan.files {
                let dst = confDir.appendingPathComponent(f.name)
                if previouslyExisting.contains(f.name) {
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: backup.appendingPathComponent(f.name), to: dst)
                } else {
                    try? fm.removeItem(at: dst)
                }
            }
            throw error
        }

        // Catégories décochées : leurs fichiers ne sont plus référencés, on les supprime.
        for name in stale {
            try? fm.removeItem(at: confDir.appendingPathComponent(name))
            report.removed.append(name)
        }
        return report
    }

    /// Met le filtrage en pause sans rien télécharger ni supprimer : le bloc KidSafe de la config
    /// ne charge plus aucun fichier. La reprise se fait par un `install` complet.
    public func pause(options: PrivoxyConfigEditor.Options) throws {
        var opts = options
        opts.active = false
        let old = try String(contentsOf: configFile, encoding: .utf8)
        let new = PrivoxyConfigEditor.apply(actionFiles: [], to: old, options: opts)
        guard new != old else { return }
        try writeAtomically(new, to: configFile, keepAttributesOf: configFile)
        if let bin = privoxyBinary {
            do { try configTest(binary: bin) } catch {
                try? writeAtomically(old, to: configFile, keepAttributesOf: configFile)
                throw error
            }
        }
    }

    /// Réapplique les options (éditeur, journal…) sans rien télécharger : même liste de fichiers,
    /// test de la config, retour arrière si Privoxy la refuse. Privoxy relit la config tout seul.
    public func updateOptions(_ options: PrivoxyConfigEditor.Options) throws {
        let old = try String(contentsOf: configFile, encoding: .utf8)
        guard old.contains(PrivoxyConfigEditor.beginMarker) else { return }
        var opts = options
        opts.active = !PrivoxyConfigEditor.isPaused(old)
        let new = PrivoxyConfigEditor.apply(actionFiles: PrivoxyConfigEditor.managedActionFiles(in: old), to: old, options: opts)
        guard new != old else { return }
        try writeAtomically(new, to: configFile, keepAttributesOf: configFile)
        if let bin = privoxyBinary {
            do { try configTest(binary: bin) } catch {
                try? writeAtomically(old, to: configFile, keepAttributesOf: configFile)
                throw error
            }
        }
    }

    /// Teste la configuration actuelle (après une modification manuelle de user.action, par exemple).
    public func testConfig() throws {
        if let bin = privoxyBinary { try configTest(binary: bin) }
    }

    public func isPaused() -> Bool {
        (try? String(contentsOf: configFile, encoding: .utf8)).map(PrivoxyConfigEditor.isPaused) ?? false
    }

    /// Réécrit un fichier déjà référencé par la config, seulement si son contenu change.
    /// Renvoie vrai s'il a été réécrit.
    @discardableResult
    public func refreshFile(_ name: String, content: String) throws -> Bool {
        let url = confDir.appendingPathComponent(name)
        if let current = try? String(contentsOf: url, encoding: .utf8), current == content { return false }
        try writeAtomically(content, to: url)
        return true
    }

    /// Désinstalle complètement KidSafe de la configuration Privoxy.
    public func uninstall() throws -> Report {
        var report = Report()
        let old = try String(contentsOf: configFile, encoding: .utf8)
        let new = PrivoxyConfigEditor.remove(from: old)
        if new != old {
            try writeAtomically(new, to: configFile, keepAttributesOf: configFile)
            report.configChanged = true
        }
        for name in try existingKidSafeFiles() {
            try FileManager.default.removeItem(at: confDir.appendingPathComponent(name))
            report.removed.append(name)
        }
        return report
    }

    // MARK: -

    private func existingKidSafeFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: confDir.path)
            .filter { $0.hasPrefix(PrivoxyActions.filePrefix) && $0.hasSuffix(".action") }
            .sorted()
    }

    /// Écrit dans un fichier temporaire du même dossier puis renomme : Privoxy ne voit jamais
    /// un fichier à moitié écrit. Les fichiers générés sont en 0644 (lisibles, non modifiables par Privoxy).
    private func writeAtomically(_ content: String, to url: URL, keepAttributesOf original: URL? = nil) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".kidsafe-tmp-\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: Data(content.utf8), attributes: [.posixPermissions: 0o644]) else {
            throw KidSafeError.io(L("error.writeDir", url.deletingLastPathComponent().path))
        }
        if let original, let attrs = try? fm.attributesOfItem(atPath: original.path) {
            var keep: [FileAttributeKey: Any] = [:]
            for k in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID] { keep[k] = attrs[k] }
            try? fm.setAttributes(keep, ofItemAtPath: tmp.path)
        }
        if rename(tmp.path, url.path) != 0 {
            let why = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            throw KidSafeError.io(L("error.replace", url.path, why))
        }
    }

    private func configTest(binary: URL) throws {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--no-daemon", "--config-test", configFile.path]
        p.currentDirectoryURL = confDir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw KidSafeError.configTestFailed(String(decoding: data, as: UTF8.self))
        }
    }
}
