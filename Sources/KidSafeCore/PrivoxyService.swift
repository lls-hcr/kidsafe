import Foundation

/// Contrôle du service Privoxy lancé par launchd.
///
/// Les navigateurs gardent ouverts les tunnels HTTPS (CONNECT) vers les sites déjà visités ;
/// Privoxy ne vérifie un site qu'à l'ouverture du tunnel. Après un nouveau blocage, on redémarre
/// Privoxy pour couper ces tunnels, sinon un onglet déjà ouvert continuerait de fonctionner.
public enum PrivoxyService {
    /// Libellé launchd du service Privoxy de l'utilisateur (Homebrew : `sh.brew.privoxy`
    /// ou `homebrew.mxcl.privoxy`). Le service système du .pkg passera par le helper root.
    public static func userServiceLabel() -> String? {
        guard let out = run("/bin/launchctl", ["list"]) else { return nil }
        for line in out.split(separator: "\n") {
            guard let label = line.split(separator: "\t").last.map(String.init) else { continue }
            if label.lowercased().contains("privoxy") { return label }
        }
        return nil
    }

    /// Redémarre Privoxy (coupe toutes les connexions ouvertes). Renvoie vrai si c'est fait.
    @discardableResult
    public static func restart() -> Bool {
        guard let label = userServiceLabel() else { return false }
        return run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"]) != nil
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
