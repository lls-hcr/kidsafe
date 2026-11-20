import Foundation

/// Textes traduits (fr, en) partagés par le cœur, la CLI et l'app.
public enum Localization {
    /// Bundle des ressources de KidSafeCore. Dans le .app, il est copié dans
    /// `Contents/Resources` (emplacement compatible avec la signature du code) ;
    /// en développement, c'est le bundle généré par SwiftPM.
    public static let bundle: Bundle = {
        let name = "KidSafe_KidSafeCore.bundle"
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        for base in bases.compactMap({ $0 }) {
            if let b = Bundle(url: base.appendingPathComponent(name)) { return b }
        }
        return Bundle.module
    }()

    /// Langue forcée (`"fr"`, `"en"`) ; `nil` suit la langue du système.
    nonisolated(unsafe) public static var forcedLanguage: String? = nil {
        didSet { cache = nil }
    }
    nonisolated(unsafe) private static var cache: Bundle?

    static var activeBundle: Bundle {
        if let cache { return cache }
        var b = bundle
        if let lang = forcedLanguage ?? environmentLanguage,
           let path = bundle.path(forResource: lang, ofType: "lproj"), let lb = Bundle(path: path) {
            b = lb
        }
        cache = b
        return b
    }

    /// `KIDSAFE_LANG=en kidsafe-blocklist …` force la langue de la CLI.
    private static var environmentLanguage: String? {
        ProcessInfo.processInfo.environment["KIDSAFE_LANG"]
    }

    public static var currentLanguage: String {
        forcedLanguage ?? environmentLanguage ?? bundle.preferredLocalizations.first ?? "fr"
    }
}

/// Texte traduit ; les arguments remplacent `%@`, `%d`… dans l'ordre.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Localization.activeBundle.localizedString(forKey: key, value: nil, table: nil)
    return args.isEmpty ? format : String(format: format, locale: Locale(identifier: Localization.currentLanguage), arguments: args)
}

/// Nombre formaté selon la langue (« 87 887 » / « 87,887 »).
public func formatCount(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: Localization.currentLanguage)
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}
