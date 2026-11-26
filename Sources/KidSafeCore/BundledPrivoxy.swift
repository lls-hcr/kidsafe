import Darwin
import Foundation

/// Privoxy intégré à Yamoxy.app (compilé par scripts/build-privoxy.sh) :
/// - binaire : `Yamoxy.app/Contents/Helpers/privoxy`
/// - fichiers par défaut : `Yamoxy.app/Contents/Resources/privoxy-conf/`
///
/// Au lancement, ils sont installés dans `<supportDir>/privoxy/` (copie modifiable, sans
/// attribut de quarantaine). Le port est dédié pour ne jamais entrer en conflit avec un autre Privoxy.
public enum BundledPrivoxy {
    public static let port = 8128
    /// Plage où chercher un port libre si le port choisi est déjà pris par un autre programme.
    public static let portRange = 8128...8199

    public static func binary(in bundle: Bundle) -> URL? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/privoxy")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public static func defaults(in bundle: Bundle) -> URL? {
        bundle.resourceURL?.appendingPathComponent("privoxy-conf", isDirectory: true)
    }

    public static func installDir(supportDir: URL) -> URL { supportDir.appendingPathComponent("privoxy", isDirectory: true) }

    /// Marque « version de l'app / version de Privoxy » de la copie installée (`.kidsafe-bundle` avant Yamoxy).
    static let stampNames = [".yamoxy-bundle", ".kidsafe-bundle"]

    /// Efface la marque : au prochain `prepare`, la config est régénérée (nouveaux chemins complets).
    public static func forgetStamp(supportDir: URL) {
        for name in stampNames { try? FileManager.default.removeItem(at: installDir(supportDir: supportDir).appendingPathComponent(name)) }
    }

    /// Arrête le Privoxy intégré lancé depuis ce dossier (jamais un autre Privoxy) et attend qu'il soit arrêté.
    public static func stopRunning(supportDir: URL) {
        let bin = installDir(supportDir: supportDir).appendingPathComponent("bin/privoxy").path
        func running() -> Bool { tool("/usr/bin/pgrep", ["-U", "\(getuid())", "-f", bin]) == 0 }
        guard running() else { return }
        _ = tool("/usr/bin/pkill", ["-U", "\(getuid())", "-f", bin])
        let end = Date().addingTimeInterval(5)
        while running() && Date() < end { usleep(100_000) }
        if running() { _ = tool("/usr/bin/pkill", ["-9", "-U", "\(getuid())", "-f", bin]); usleep(300_000) }
    }

    @discardableResult
    static func tool(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Fichiers de règles laissés par KidSafe (`kidsafe-*.action`) : recopiés sous leur nouveau nom
    /// (`yamoxy-*.action`, motif « Yamoxy : »). Renvoie la correspondance ancien nom → nouveau nom.
    /// Les anciens fichiers sont supprimés par l'appelant, une fois la nouvelle config écrite.
    static func convertLegacyActionFiles(in dir: URL) -> [String: String] {
        let fm = FileManager.default
        var renamed: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasPrefix(PrivoxyActions.legacyFilePrefix) && name.hasSuffix(".action") {
            let newName = PrivoxyActions.filePrefix + name.dropFirst(PrivoxyActions.legacyFilePrefix.count)
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            let converted = PrivoxyActions.rebrand(text)
            let dst = dir.appendingPathComponent(newName)
            guard (try? converted.write(to: dst, atomically: true, encoding: .utf8)) != nil else { continue }
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dst.path)
            renamed[name] = newName
        }
        return renamed
    }

    /// Prépare (ou met à jour) la copie de Privoxy et renvoie l'installateur correspondant.
    /// Les listes déjà installées et l'état de pause sont conservés.
    public static func prepare(bundle: Bundle = .main, supportDir: URL, port: Int = BundledPrivoxy.port) throws -> PrivoxyInstaller? {
        guard let srcBin = binary(in: bundle), let srcConf = defaults(in: bundle) else { return nil }
        let fm = FileManager.default
        let dir = installDir(supportDir: supportDir)
        let bin = dir.appendingPathComponent("bin/privoxy")
        let config = dir.appendingPathComponent("config")
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("log"), withIntermediateDirectories: true)

        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        let privoxyVersion = (try? String(contentsOf: srcConf.appendingPathComponent("VERSION"), encoding: .utf8)) ?? "?"
        let stamp = "\(appVersion)/\(privoxyVersion.trimmingCharacters(in: .whitespacesAndNewlines))"
        let stampFile = dir.appendingPathComponent(stampNames[0])
        let upToDate = (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp
            && fm.isExecutableFile(atPath: bin.path) && fm.fileExists(atPath: config.path)

        if !upToDate {
            // Binaire : copie sans quarantaine, sinon macOS pourrait refuser de le lancer.
            try? fm.removeItem(at: bin)
            try fm.copyItem(at: srcBin, to: bin)
            removexattr(bin.path, "com.apple.quarantine", 0)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

            // Fichiers de Privoxy : remplacés à chaque version ; ceux de l'utilisateur conservés.
            for name in ["match-all.action", "default.action", "default.filter", "trust"] {
                try replace(dir.appendingPathComponent(name), with: srcConf.appendingPathComponent(name))
            }
            for name in ["user.action", "user.filter"] where !fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
                try fm.copyItem(at: srcConf.appendingPathComponent(name), to: dir.appendingPathComponent(name))
            }
            try replace(dir.appendingPathComponent("templates"), with: srcConf.appendingPathComponent("templates"))

            // Config : modèle de la nouvelle version + bloc géré de l'ancienne (y compris celui de KidSafe,
            // dont les fichiers sont repris sous leur nouveau nom).
            let template = try String(contentsOf: srcConf.appendingPathComponent("config"), encoding: .utf8)
            var new = adapt(template, dir: dir, port: port)
            let renamed = convertLegacyActionFiles(in: dir)
            if let old = try? String(contentsOf: config, encoding: .utf8), PrivoxyConfigEditor.hasBlock(old) {
                let files = PrivoxyConfigEditor.managedActionFiles(in: old).map { renamed[$0] ?? $0 }
                new = PrivoxyConfigEditor.apply(actionFiles: files, to: new,
                                                options: .init(active: !PrivoxyConfigEditor.isPaused(old)))
            }
            try new.write(to: config, atomically: true, encoding: .utf8)
            for name in renamed.keys { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            for name in stampNames.dropFirst() { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
            try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        }
        return PrivoxyInstaller(confDir: dir, configFile: config, privoxyBinary: bin)
    }

    /// Chemins absolus, journal dans `log/`, écoute locale sur le port dédié.
    static func adapt(_ template: String, dir: URL, port: Int = BundledPrivoxy.port) -> String {
        template.components(separatedBy: "\n").map { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("confdir ") { return "confdir \(dir.path)" }
            if t.hasPrefix("logdir ") { return "logdir \(dir.appendingPathComponent("log").path)" }
            if t.hasPrefix("listen-address ") { return "listen-address  127.0.0.1:\(port)" }
            // Option de l'inspection HTTPS, absente de notre Privoxy (compilé sans TLS) : évite l'avertissement.
            if t.hasPrefix("elliptic-curve-keys ") { return "#" + line + "   # Yamoxy : sans objet (Privoxy compilé sans TLS)" }
            return line
        }.joined(separator: "\n")
    }

    /// Réinitialise les fichiers de Privoxy (y compris user.action et user.filter) depuis l'app.
    /// Les listes et l'état de pause sont conservés.
    public static func reset(bundle: Bundle = .main, supportDir: URL, port: Int) throws -> PrivoxyInstaller? {
        let dir = installDir(supportDir: supportDir)
        for name in stampNames + ["user.action", "user.filter"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return try prepare(bundle: bundle, supportDir: supportDir, port: port)
    }

    /// Change le port d'écoute dans la config (Privoxy doit ensuite être redémarré).
    public static func setPort(_ port: Int, configFile: URL) throws {
        let old = try String(contentsOf: configFile, encoding: .utf8)
        let new = old.components(separatedBy: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("listen-address ") ? "listen-address  127.0.0.1:\(port)" : line
        }.joined(separator: "\n")
        try new.write(to: configFile, atomically: true, encoding: .utf8)
    }

    /// Premier port libre de la plage (en commençant par `preferred`).
    public static func freePort(preferred: Int) -> Int? {
        ([preferred] + Array(portRange)).first { !PrivoxyController.isListening(host: "127.0.0.1", port: $0) }
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
    }
}

/// Remet le Mac dans son état d'origine. Partagé par l'app (Réglages → Désinstaller)
/// et par l'outil « Désinstaller Yamoxy » du .dmg.
public enum KidSafeUninstaller {
    public static let bundleID = "app.kidsafe.KidSafe"

    /// Renvoie un message d'erreur si le proxy n'a pas pu être retiré : dans ce cas rien d'autre
    /// n'est fait, pour ne jamais laisser le Mac pointer vers un Privoxy arrêté.
    public static func perform(paths: KidSafePaths, endpoints: [SystemStatus.Endpoint], adminPrompt: String?) -> String? {
        for e in endpoints where !SystemStatus.servicesUsingProxy(e).isEmpty {
            if let err = SystemStatus.setSystemProxy(e, enable: false, prompt: adminPrompt) { return err }
        }
        // Privoxy intégré (lancé par l'app) : arrêté par son chemin, jamais un autre Privoxy.
        // Le dossier de l'app, et celui de KidSafe s'il est resté (ancien nom).
        var dirs = [paths.supportDir]
        if paths.supportDir == KidSafePaths.user.supportDir {
            dirs += KidSafePaths.allExisting.map(\.supportDir).filter { $0 != paths.supportDir }
        }
        for dir in dirs {
            let bin = BundledPrivoxy.installDir(supportDir: dir).appendingPathComponent("bin/privoxy").path
            run("/usr/bin/pkill", ["-U", "\(getuid())", "-f", bin])
        }
        // Ancienne installation de test : bloc géré dans la config d'un Privoxy Homebrew.
        if let brew = PrivoxyInstaller.detectExternal() { _ = try? brew.uninstall() }
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        return nil
    }

    private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
