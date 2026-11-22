import Foundation
import Darwin

/// État du système vu par l'app : Privoxy répond-il, le proxy système pointe-t-il dessus ?
public enum SystemStatus {
    /// Domaines exclus du proxy (`-setproxybypassdomains`), tenus à jour par l'app.
    nonisolated(unsafe) public static var bypassDomains = AdvancedSettings.systemBypass

    public struct Endpoint: Equatable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) { self.host = host; self.port = port }
    }

    /// Adresse d'écoute de Privoxy (`listen-address` de la config, 127.0.0.1:8118 par défaut).
    public static func listenAddress(configFile: URL) -> Endpoint {
        let fallback = Endpoint(host: "127.0.0.1", port: 8118)
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { return fallback }
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0] == "listen-address" else { continue }
            let addr = String(parts[1])
            guard let colon = addr.lastIndex(of: ":"), let port = Int(addr[addr.index(after: colon)...]) else { continue }
            var host = String(addr[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if host.isEmpty || host == "0.0.0.0" { host = "127.0.0.1" }
            return Endpoint(host: host, port: port)
        }
        return fallback
    }

    /// Vrai si quelque chose écoute sur l'adresse (connexion TCP de test).
    public static func isListening(_ e: Endpoint) -> Bool { PrivoxyController.isListening(host: e.host, port: e.port) }

    /// Le proxy HTTP et HTTPS du système pointe-t-il vers Privoxy ? (`scutil --proxy`, sans droits admin)
    public static func systemProxyPointsTo(_ e: Endpoint) -> Bool {
        guard let out = run("/usr/sbin/scutil", ["--proxy"]) else { return false }
        var v: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { v[kv[0]] = kv[1] }
        }
        let hosts = [e.host, "localhost", "127.0.0.1"]
        return v["HTTPEnable"] == "1" && v["HTTPSEnable"] == "1"
            && hosts.contains(v["HTTPProxy"] ?? "") && hosts.contains(v["HTTPSProxy"] ?? "")
            && v["HTTPPort"] == "\(e.port)" && v["HTTPSPort"] == "\(e.port)"
    }

    /// Services réseau actifs (Wi-Fi, Ethernet…).
    public static func networkServices() -> [String] {
        guard let list = run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return [] }
        return list.split(separator: "\n").dropFirst()            // 1re ligne : explication
            .map(String.init).filter { !$0.hasPrefix("*") }        // `*` = service désactivé
    }

    /// Services dont le proxy web (HTTP ou HTTPS) est activé et pointe vers Privoxy.
    /// Seuls ceux-là sont modifiés au retrait : un proxy configuré par ailleurs n'est jamais touché.
    public static func servicesUsingProxy(_ e: Endpoint, among list: [String]? = nil) -> [String] {
        let hosts: Set<String> = [e.host, "127.0.0.1", "localhost"]
        // Lectures en parallèle (une par service et par protocole) : ~0,1 s au lieu de ~0,7 s.
        let services = list ?? networkServices()
        var using = [Bool](repeating: false, count: services.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: services.count) { i in
            let s = services[i]
            let hit = ["-getwebproxy", "-getsecurewebproxy"].contains { flag in
                guard let out = run("/usr/sbin/networksetup", [flag, s]) else { return false }
                var v: [String: String] = [:]
                for line in out.split(separator: "\n") {
                    let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { v[kv[0]] = kv[1] }
                }
                return v["Enabled"] == "Yes" && hosts.contains(v["Server"] ?? "") && v["Port"] == "\(e.port)"
            }
            lock.lock(); using[i] = hit; lock.unlock()
        }
        return services.indices.filter { using[$0] }.map { services[$0] }
    }

    /// Active (`enable`) ou retire Privoxy comme proxy HTTP/HTTPS du Mac.
    /// Essaie d'abord sans mot de passe (suffit pour un compte administrateur) ; sinon, si `prompt`
    /// est fourni, macOS demande le mot de passe administrateur. Renvoie un message d'erreur ou nil.
    @discardableResult
    public static func setSystemProxy(_ e: Endpoint, enable: Bool, prompt: String?) -> String? {
        let services = enable ? networkServices() : servicesUsingProxy(e)
        let cmds: [[String]] = services.flatMap { s -> [[String]] in
            enable ? [["-setwebproxy", s, e.host, "\(e.port)"], ["-setsecurewebproxy", s, e.host, "\(e.port)"],
                      ["-setproxybypassdomains", s] + bypassDomains]
                   : [["-setwebproxystate", s, "off"], ["-setsecurewebproxystate", s, "off"]]
        }
        // Vérification ciblée : seulement les services modifiés (chaque appel à networksetup coûte ~30 ms).
        let done = { enable ? systemProxyPointsTo(e) : servicesUsingProxy(e, among: services).isEmpty }
        if cmds.isEmpty { return nil }
        for c in cmds { _ = run("/usr/sbin/networksetup", c) }
        // networksetup ne signale pas toujours un refus d'autorisation : on vérifie le résultat.
        for attempt in 0..<3 {
            if done() { return nil }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.2) }
        }
        guard let prompt else { return "networksetup" }

        return AdminShell.run(cmds.map { ["/usr/sbin/networksetup"] + $0 }, prompt: prompt)
    }

    private static func run(_ tool: String, _ args: [String], requireSuccess: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if requireSuccess, p.terminationStatus != 0 { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
