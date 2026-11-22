import CoreFoundation
import Foundation

/// Commandes lancées avec les droits administrateur. macOS affiche sa propre fenêtre :
/// KidSafe ne voit jamais le mot de passe.
public enum AdminShell {
    /// Renvoie nil si tout s'est bien passé, sinon le message d'erreur (`-128` : annulé par l'utilisateur).
    public static func run(_ commands: [[String]], prompt: String) -> String? {
        guard !commands.isEmpty else { return nil }
        let shell = commands.map { $0.map(quote).joined(separator: " ") }.joined(separator: " && ")
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with prompt \"\(prompt.replacingOccurrences(of: "\"", with: "'"))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run() } catch { return "\(error)" }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func isCancel(_ error: String) -> Bool { error.contains("-128") }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Règle de Firefox « utiliser le proxy du système », verrouillée. Firefox peut sinon ignorer
/// le proxy de macOS (Paramètres → Réseau → « Pas de proxy »). La règle est écrite dans les
/// préférences du système (`/Library/Preferences/org.mozilla.firefox`, méthode documentée par Mozilla) :
/// elle vaut pour tous les comptes et toutes les copies de Firefox, sans modifier l'app (sa signature reste intacte).
public enum FirefoxPolicy {
    public static let bundleID = "org.mozilla.firefox"
    static let domainPath = "/Library/Preferences/org.mozilla.firefox"
    static let enableKey = "EnterprisePoliciesEnabled"
    static let proxyKey = "Proxy"
    static var proxyRule: [String: Any] { ["Mode": "system", "Locked": true] }

    /// La règle est-elle en place ?
    public static var isInstalled: Bool { isInstalled(read()) }

    static func isInstalled(_ prefs: [String: Any]) -> Bool {
        guard prefs[enableKey] as? Bool == true, let proxy = prefs[proxyKey] as? [String: Any] else { return false }
        return proxy["Mode"] as? String == "system" && proxy["Locked"] as? Bool == true
    }

    /// Ajoute la règle, sans toucher aux autres règles éventuelles du parent.
    public static func install(prompt: String) -> String? {
        write(merged(read()), prompt: prompt)
    }

    /// Retire la règle de KidSafe (les autres règles éventuelles restent).
    public static func remove(prompt: String) -> String? {
        let prefs = read()
        guard prefs[proxyKey] != nil else { return nil }
        return write(removed(prefs), prompt: prompt)
    }

    static func merged(_ prefs: [String: Any]) -> [String: Any] {
        var p = prefs
        p[enableKey] = true
        p[proxyKey] = proxyRule
        return p
    }

    static func removed(_ prefs: [String: Any]) -> [String: Any] {
        var p = prefs
        p[proxyKey] = nil
        if Set(p.keys) == [enableKey] { p = [:] }   // plus aucune règle : on n'active plus les règles
        return p
    }

    /// Préférences de Firefox pour tous les utilisateurs (`/Library/Preferences`), lues via cfprefsd.
    static func read() -> [String: Any] {
        let app = bundleID as CFString
        CFPreferencesSynchronize(app, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String],
              let values = CFPreferencesCopyMultiple(keys as CFArray, app, kCFPreferencesAnyUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return [:] }
        return values
    }

    /// `defaults import` (ou `delete`) en administrateur : passe par cfprefsd, que Firefox lit au lancement.
    private static func write(_ prefs: [String: Any], prompt: String) -> String? {
        if prefs.isEmpty { return AdminShell.run([["/usr/bin/defaults", "delete", domainPath]], prompt: prompt) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-firefox-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
            try data.write(to: tmp)
        } catch { return "\(error)" }
        let err = AdminShell.run([["/usr/bin/defaults", "import", domainPath, tmp.path]], prompt: prompt)
        CFPreferencesSynchronize(bundleID as CFString, kCFPreferencesAnyUser, kCFPreferencesAnyHost)
        return err
    }
}

/// Événements montrés au parent dans le moniteur : arrêts inattendus de KidSafe, ouverture au démarrage
/// désactivée en dehors de KidSafe. Fichier `events.json` du dossier de KidSafe (50 derniers).
public enum EventLog {
    public enum Kind: String, Codable, Sendable { case unexpectedStop, loginItemDisabled }

    public struct Event: Codable, Equatable, Sendable {
        public var date: Date
        public var kind: Kind
        /// Arrêt inattendu : dernier signe de vie de KidSafe avant l'arrêt.
        public var lastSeen: Date?
        public init(date: Date, kind: Kind, lastSeen: Date? = nil) { self.date = date; self.kind = kind; self.lastSeen = lastSeen }
    }

    public static let keep = 50
    /// Le moniteur signale les événements de la dernière semaine.
    public static let recentInterval: TimeInterval = 7 * 24 * 3600

    public static func file(supportDir: URL) -> URL { supportDir.appendingPathComponent("events.json") }

    public static func load(_ file: URL) -> [Event] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([Event].self, from: data)) ?? []
    }

    public static func append(_ event: Event, to file: URL) {
        let events = Array((load(file) + [event]).suffix(keep))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted
        guard let data = try? e.encode(events) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public static func recent(_ file: URL, now: Date = Date()) -> [Event] {
        load(file).filter { now.timeIntervalSince($0.date) < recentInterval }.reversed()
    }

    /// Texte affiché au parent.
    public static func describe(_ e: Event, locale: Locale) -> String {
        func t(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) }
        switch e.kind {
        case .unexpectedStop:
            return L("event.unexpectedStop", e.lastSeen.map(t) ?? "?", t(e.date))
        case .loginItemDisabled:
            return L("event.loginItemDisabled", t(e.date))
        }
    }
}

/// Signe de vie de KidSafe : un fichier mis à jour toutes les 30 s et supprimé quand KidSafe quitte normalement.
/// S'il est encore là au lancement suivant, KidSafe a été arrêté sans passer par « Quitter »
/// (arrêt forcé, plantage, coupure de courant).
public enum Heartbeat {
    public static func file(supportDir: URL) -> URL { supportDir.appendingPathComponent("running") }

    public static func beat(_ file: URL, now: Date = Date()) {
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.modificationDate: now])
        }
    }

    /// Dernier signe de vie, si KidSafe ne s'est pas arrêté normalement.
    public static func lastBeat(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    public static func clear(_ file: URL) { try? FileManager.default.removeItem(at: file) }
}
