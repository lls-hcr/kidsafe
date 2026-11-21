import Foundation
import Darwin
import KidSafeCore

/// État du système vu par l'app : Privoxy répond-il, le proxy système pointe-t-il dessus ?
enum SystemStatus {
    struct Endpoint: Equatable { var host: String; var port: Int }

    /// Adresse d'écoute de Privoxy (`listen-address` de la config, 127.0.0.1:8118 par défaut).
    static func listenAddress(configFile: URL) -> Endpoint {
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
    static func isListening(_ e: Endpoint) -> Bool { PrivoxyController.isListening(host: e.host, port: e.port) }

    /// Le proxy HTTP et HTTPS du système pointe-t-il vers Privoxy ? (`scutil --proxy`, sans droits admin)
    static func systemProxyPointsTo(_ e: Endpoint) -> Bool {
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
    static func networkServices() -> [String] {
        guard let list = run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return [] }
        return list.split(separator: "\n").dropFirst()            // 1re ligne : explication
            .map(String.init).filter { !$0.hasPrefix("*") }        // `*` = service désactivé
    }

    /// Services dont le proxy web (HTTP ou HTTPS) est activé et pointe vers Privoxy.
    /// Seuls ceux-là sont modifiés au retrait : un proxy configuré par ailleurs n'est jamais touché.
    static func servicesUsingProxy(_ e: Endpoint) -> [String] {
        let hosts: Set<String> = [e.host, "127.0.0.1", "localhost"]
        return networkServices().filter { s in
            ["-getwebproxy", "-getsecurewebproxy"].contains { flag in
                guard let out = run("/usr/sbin/networksetup", [flag, s]) else { return false }
                var v: [String: String] = [:]
                for line in out.split(separator: "\n") {
                    let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { v[kv[0]] = kv[1] }
                }
                return v["Enabled"] == "Yes" && hosts.contains(v["Server"] ?? "") && v["Port"] == "\(e.port)"
            }
        }
    }

    /// Active (`enable`) ou retire Privoxy comme proxy HTTP/HTTPS du Mac.
    /// Essaie d'abord sans mot de passe (suffit pour un compte administrateur) ; sinon, si `prompt`
    /// est fourni, macOS demande le mot de passe administrateur. Renvoie un message d'erreur ou nil.
    @discardableResult
    static func setSystemProxy(_ e: Endpoint, enable: Bool, prompt: String?) -> String? {
        let services = enable ? networkServices() : servicesUsingProxy(e)
        let cmds: [[String]] = services.flatMap { s -> [[String]] in
            enable ? [["-setwebproxy", s, e.host, "\(e.port)"], ["-setsecurewebproxy", s, e.host, "\(e.port)"],
                      ["-setproxybypassdomains", s, "localhost", "127.0.0.1", "*.local"]]
                   : [["-setwebproxystate", s, "off"], ["-setsecurewebproxystate", s, "off"]]
        }
        let done = { enable ? systemProxyPointsTo(e) : servicesUsingProxy(e).isEmpty }
        if cmds.isEmpty { return done() ? nil : "networksetup" }
        for c in cmds { _ = run("/usr/sbin/networksetup", c) }
        // networksetup ne signale pas toujours un refus d'autorisation : on vérifie le résultat.
        for _ in 0..<10 { if done() { return nil }; Thread.sleep(forTimeInterval: 0.1) }
        guard let prompt else { return "networksetup" }

        let shell = cmds.map { (["/usr/sbin/networksetup"] + $0).map(shellQuote).joined(separator: " ") }.joined(separator: " && ")
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with prompt \"\(prompt.replacingOccurrences(of: "\"", with: "'"))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run() } catch { return "\(error)" }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        return String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

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
