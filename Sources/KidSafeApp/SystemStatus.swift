import Foundation
import Darwin

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
    static func isListening(_ e: Endpoint) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(e.port).bigEndian)
        guard inet_pton(AF_INET, e.host == "localhost" ? "127.0.0.1" : e.host, &addr.sin_addr) == 1 else { return false }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

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

    /// Configure (ou retire) Privoxy comme proxy HTTP/HTTPS sur tous les services réseau.
    /// macOS demande le mot de passe administrateur ; le helper root prendra le relais plus tard.
    static func setSystemProxy(_ e: Endpoint?, prompt: String) -> String? {
        guard let list = run("/usr/sbin/networksetup", ["-listallnetworkservices"]) else { return "networksetup" }
        let services = list.split(separator: "\n").dropFirst()          // 1re ligne : explication
            .map(String.init).filter { !$0.hasPrefix("*") }              // `*` = service désactivé
        var cmds: [String] = []
        for s in services {
            let q = "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if let e {
                cmds.append("/usr/sbin/networksetup -setwebproxy \(q) \(e.host) \(e.port)")
                cmds.append("/usr/sbin/networksetup -setsecurewebproxy \(q) \(e.host) \(e.port)")
                cmds.append("/usr/sbin/networksetup -setproxybypassdomains \(q) localhost 127.0.0.1 '*.local'")
            } else {
                cmds.append("/usr/sbin/networksetup -setwebproxystate \(q) off")
                cmds.append("/usr/sbin/networksetup -setsecurewebproxystate \(q) off")
            }
        }
        let shell = cmds.joined(separator: " && ")
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

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
