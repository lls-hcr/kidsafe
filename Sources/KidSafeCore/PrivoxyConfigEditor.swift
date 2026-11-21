import Foundation

/// Modifie le fichier `config` de Privoxy de façon idempotente et réversible.
///
/// Tout ce qu'ajoute KidSafe tient dans un bloc délimité ; les directives d'origine
/// qu'il remplace sont mises en commentaire avec un préfixe reconnaissable,
/// pour pouvoir être restaurées par `remove`.
public enum PrivoxyConfigEditor {

    public static let beginMarker = "# >>> KidSafe : bloc géré automatiquement, ne pas modifier >>>"
    public static let endMarker = "# <<< KidSafe <<<"
    static let disabledPrefix = "#KidSafe-désactivé# "
    public static let pausedMarker = "KidSafe : filtrage en pause"

    /// Directives qui empêchent de désactiver le filtrage depuis le navigateur
    /// (http://config.privoxy.org/toggle, éditeur d'actions en ligne).
    public static let hardening: [(String, String)] = [
        ("toggle", "1"),
        ("enable-remote-toggle", "0"),
        ("enable-remote-http-toggle", "0"),
        ("enable-edit-actions", "0"),
        // Sans cela, la page de blocage propose « Go there anyway » : contournement en un clic.
        ("enforce-blocks", "1"),
    ]

    public struct Options: Sendable {
        public var harden = true
        /// Retire les lignes ajoutées par l'ancien privoxy-blocklist.sh (`*.script.action|filter`).
        public var removeLegacyBlocklist = false
        /// Faux : les fichiers KidSafe restent sur le disque mais ne sont plus chargés (filtrage en pause).
        public var active = true
        /// Éditeur d'actions de Privoxy (http://p.p) : ouvert seulement à la demande du parent (onglet Avancé).
        public var editActions = false
        /// Journal des requêtes bloquées (`debug 1024`), lu par l'onglet Avancé.
        public var logBlocked = false
        public init(harden: Bool = true, removeLegacyBlocklist: Bool = false, active: Bool = true,
                    editActions: Bool = false, logBlocked: Bool = false) {
            self.harden = harden
            self.removeLegacyBlocklist = removeLegacyBlocklist
            self.active = active
            self.editActions = editActions
            self.logBlocked = logBlocked
        }

        /// Options issues des réglages du parent.
        public init(catalog: Catalog) {
            self.init(harden: catalog.hardenPrivoxy, active: catalog.filteringEnabled,
                      editActions: catalog.advanced.editorActive(), logBlocked: catalog.advanced.logBlocked)
        }
    }

    /// Directives imposées par KidSafe pour ces options.
    static func directives(_ options: Options) -> [(String, String)] {
        hardening.map { $0.0 == "enable-edit-actions" ? ($0.0, options.editActions ? "1" : "0") : $0 }
    }

    /// Ajoute (ou remplace) le bloc KidSafe. `actionFiles` est dans l'ordre de chargement :
    /// Privoxy applique les fichiers dans l'ordre, le dernier qui correspond l'emporte.
    public static func apply(actionFiles: [String], to config: String, options: Options = Options()) -> String {
        var lines = splitLines(remove(from: config))
        if options.removeLegacyBlocklist {
            lines.removeAll { isLegacyBlocklistLine($0) }
        }

        var block = [beginMarker]
        if options.active {
            block += actionFiles.map { "actionsfile \($0)" }
        } else {
            block.append("# " + pausedMarker)
        }
        if options.harden {
            let names = Set(hardening.map(\.0))
            for i in lines.indices {
                if let name = directiveName(lines[i]), names.contains(name) {
                    lines[i] = disabledPrefix + lines[i]
                }
            }
            block += directives(options).map { "\($0.0) \($0.1)" }
        }
        if options.logBlocked { block.append("debug 1024   # KidSafe : journal des requêtes bloquées") }
        block.append(endMarker)

        // Avant `actionsfile user.action` pour que l'utilisateur garde le dernier mot ;
        // sinon après le dernier `actionsfile` ; sinon en fin de fichier.
        let insertAt: Int
        if let i = lines.firstIndex(where: { isActionsFile($0, named: "user.action") }) {
            insertAt = i
        } else if let i = lines.lastIndex(where: { directiveName($0) == "actionsfile" }) {
            insertAt = i + 1
        } else {
            insertAt = lines.count
        }
        lines.insert(contentsOf: block, at: insertAt)
        return joinLines(lines)
    }

    /// Retire le bloc KidSafe et restaure les directives mises en commentaire.
    public static func remove(from config: String) -> String {
        var out: [String] = []
        var inBlock = false
        for line in splitLines(config) {
            if line == beginMarker { inBlock = true; continue }
            if inBlock { if line == endMarker { inBlock = false }; continue }
            if line.hasPrefix(disabledPrefix) {
                out.append(String(line.dropFirst(disabledPrefix.count)))
            } else {
                out.append(line)
            }
        }
        return joinLines(out)
    }

    /// Vrai si le bloc KidSafe est présent et en pause.
    public static func isPaused(_ config: String) -> Bool {
        config.contains("# " + pausedMarker)
    }

    /// Fichiers `actionsfile` actuellement déclarés dans le bloc KidSafe.
    public static func managedActionFiles(in config: String) -> [String] {
        var inBlock = false, files: [String] = []
        for line in splitLines(config) {
            if line == beginMarker { inBlock = true; continue }
            if line == endMarker { break }
            if inBlock, directiveName(line) == "actionsfile" {
                files.append(line.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " "))
            }
        }
        return files
    }

    // MARK: -

    /// Nom de la directive d'une ligne active (`toggle 1` → `toggle`), `nil` pour un commentaire.
    static func directiveName(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
        return t.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
    }

    private static func isActionsFile(_ line: String, named name: String) -> Bool {
        guard directiveName(line) == "actionsfile" else { return false }
        let parts = line.split(whereSeparator: \.isWhitespace)
        return parts.count >= 2 && parts[1] == name
    }

    private static func isLegacyBlocklistLine(_ line: String) -> Bool {
        let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
        guard parts.count == 2 else { return false }
        return (parts[0] == "actionsfile" && parts[1].hasSuffix(".script.action"))
            || (parts[0] == "filterfile" && parts[1].hasSuffix(".script.filter"))
    }

    private static func splitLines(_ s: String) -> [String] {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func joinLines(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}
