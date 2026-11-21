import Darwin
import Foundation

/// Démarre, arrête et redémarre Privoxy pour l'app.
///
/// - Si un service launchd de l'utilisateur existe (`~/Library/LaunchAgents/*privoxy*.plist`,
///   créé par `brew services start privoxy`), il est utilisé.
/// - Sinon KidSafe lance Privoxy lui-même (`privoxy --no-daemon config`) et l'arrête en quittant.
///   Si l'app plante, Privoxy continue de tourner : la connexion reste disponible.
public final class PrivoxyController: @unchecked Sendable {
    public enum Mode: Equatable, Sendable { case none, launchd(String), child, external }

    public let binary: URL?
    public let configFile: URL
    public let host: String
    public let port: Int
    /// Faux pour le Privoxy intégré : on ne passe jamais par un service Homebrew.
    public let useLaunchAgent: Bool
    public private(set) var mode: Mode = .none
    private var child: Process?
    private let lock = NSLock()

    public init(binary: URL?, configFile: URL, host: String, port: Int, useLaunchAgent: Bool = true) {
        self.binary = binary; self.configFile = configFile; self.host = host; self.port = port
        self.useLaunchAgent = useLaunchAgent
    }

    public var isListening: Bool { Self.isListening(host: host, port: port) }

    /// Démarre Privoxy s'il ne répond pas encore. Renvoie vrai s'il répond.
    @discardableResult
    public func start(timeout: TimeInterval = 8) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isListening {
            if case .none = mode { mode = (useLaunchAgent ? loadedLabel() : nil).map { .launchd($0) } ?? .external }
            return true
        }
        if useLaunchAgent, let (label, plist) = launchAgent() {
            let target = "gui/\(getuid())/\(label)"
            if run("/bin/launchctl", ["print", target]) == nil {
                _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
            } else {
                _ = run("/bin/launchctl", ["kickstart", target])
            }
            if waitUntil(listening: true, timeout: timeout) { mode = .launchd(label); return true }
        }
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--no-daemon", configFile.path]
        p.currentDirectoryURL = configFile.deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        child = p
        mode = .child
        return waitUntil(listening: true, timeout: timeout)
    }

    /// Arrête Privoxy, quelle que soit la façon dont il a été lancé.
    public func stop(timeout: TimeInterval = 5) {
        lock.lock(); defer { lock.unlock() }
        if case .none = mode, isListening { mode = (useLaunchAgent ? loadedLabel() : nil).map { .launchd($0) } ?? .external }
        switch mode {
        case .child:
            child?.terminate()
            child?.waitUntilExit()
            child = nil
        case .launchd(let label):
            // KeepAlive : un simple kill le relancerait ; bootout décharge le service.
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        case .external, .none:
            break
        }
        if !waitUntil(listening: false, timeout: timeout) {
            // Seulement le Privoxy qui utilise notre config, jamais un autre.
            _ = run("/usr/bin/pkill", ["-U", "\(getuid())", "-f", configFile.path])
            _ = waitUntil(listening: false, timeout: 2)
        }
        mode = .none
    }

    /// Redémarre Privoxy : coupe les connexions déjà ouvertes (onglets vers des sites désormais bloqués).
    @discardableResult
    public func restart() -> Bool {
        if case .launchd(let label) = mode {
            lock.lock()
            _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
            lock.unlock()
            return waitUntil(listening: true, timeout: 8)
        }
        stop()
        return start()
    }

    // MARK: -

    public static func isListening(host: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else { return false }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    private func waitUntil(listening: Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if isListening == listening { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < end
        return isListening == listening
    }

    /// Service launchd de Privoxy de l'utilisateur (libellé, fichier plist).
    private func launchAgent() -> (String, URL)? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let f = files.first(where: { $0.lowercased().contains("privoxy") && $0.hasSuffix(".plist") }) else { return nil }
        return (String(f.dropLast(".plist".count)), dir.appendingPathComponent(f))
    }

    private func loadedLabel() -> String? {
        guard let out = run("/bin/launchctl", ["list"]) else { return nil }
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: "\t")
            guard cols.count == 3, let label = cols.last.map(String.init), label.lowercased().contains("privoxy"),
                  Int(cols[0]) != nil else { continue }   // colonne PID renseignée : en cours d'exécution
            return label
        }
        return nil
    }

    private func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
