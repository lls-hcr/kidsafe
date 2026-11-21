import Darwin
import Foundation

/// Statistiques du moniteur. Tout est lu à la demande (fenêtre ouverte ou clic sur « Mode détaillé ») :
/// rien ne tourne en arrière-plan et rien n'est enregistré en plus du journal des sites bloqués.
public enum Monitor {

    // MARK: - Compteurs de Privoxy

    public struct Counters: Sendable, Equatable {
        public var requests: Int
        public var blocked: Int
        /// Démarrage de Privoxy (les compteurs repartent de zéro à chaque démarrage).
        public var since: Date?
        public var blockedPercent: Double { requests > 0 ? Double(blocked) * 100 / Double(requests) : 0 }
        public init(requests: Int, blocked: Int, since: Date?) { self.requests = requests; self.blocked = blocked; self.since = since }
    }

    /// Lit les compteurs que Privoxy tient en mémoire (page http://p.p/show-status).
    /// Requête HTTP envoyée directement à Privoxy sur 127.0.0.1 : pas de URLSession, donc pas de blocage
    /// par App Transport Security (qui refuse le HTTP non chiffré dans les apps) et aucun réglage de proxy.
    public static func counters(host: String, port: Int) async -> Counters? {
        await Task.detached {
            guard let html = rawGet(host: host, port: port, url: "http://p.p/show-status"),
                  var c = parseCounters(html) else { return nil }
            c.since = startDate(port: port)
            return c
        }.value
    }

    /// GET minimal en HTTP/1.0 via le proxy (forme absolue de l'URL), délai de 3 s.
    static func rawGet(host: String, port: Int, url: String, timeout: Int = 3) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        guard inet_pton(AF_INET, host == "localhost" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        let hostHeader = URL(string: url)?.host ?? "p.p"
        let request = "GET \(url) HTTP/1.0\r\nHost: \(hostHeader)\r\nUser-Agent: KidSafe\r\nConnection: close\r\n\r\n"
        guard request.withCString({ send(fd, $0, strlen($0), 0) }) > 0 else { return nil }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while data.count < 2_000_000 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
    }

    /// « 519 out of 3587 requests have been blocked »
    static func parseCounters(_ html: String) -> Counters? {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        guard let r = text.range(of: #"(\d+)\s+out of\s+(\d+)\s+requests"#, options: .regularExpression) else { return nil }
        let nums = text[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return Counters(requests: nums[1], blocked: nums[0], since: nil)
    }

    /// Heure de démarrage du programme qui écoute sur le port (`ps -o lstart`).
    static func startDate(port: Int) -> Date? {
        guard let pid = run("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"])?.split(separator: "\n").first,
              let lstart = run("/bin/ps", ["-o", "lstart=", "-p", String(pid)]) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f.date(from: lstart.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "  ", with: " "))
    }

    private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: d, as: UTF8.self) : nil
    }

    // MARK: - Domaines dans les listes, catégories

    /// Index « domaine → catégorie » construit à partir des fichiers kidsafe-*.action (seulement pour la page détaillée).
    public struct CategoryIndex: Sendable {
        var map: [String: String] = [:]
        public var domainCount: Int { map.count }

        public init(confDir: URL) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: confDir.path))?
                .filter { $0.hasPrefix(PrivoxyActions.filePrefix) && $0.hasSuffix(".action") && $0 != PrivoxyActions.allowFileName }
                .sorted() ?? []
            for name in files {
                guard let text = try? String(contentsOf: confDir.appendingPathComponent(name), encoding: .utf8) else { continue }
                var current: String?
                for raw in text.split(separator: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("{") {
                        // { +block{KidSafe : Contenus pour adultes} }   ou   { -block }
                        if let r = line.range(of: #"\+block\{([^}]*)\}"#, options: .regularExpression) {
                            let name = String(line[r].dropFirst(7).dropLast()).replacingOccurrences(of: "KidSafe : ", with: "")
                            current = name.prefix(1).uppercased() + name.dropFirst()
                        } else {
                            current = ""   // section { -block } : exceptions
                        }
                    } else if let c = current, !line.isEmpty, !line.hasPrefix("#"), line != "/" {
                        map[line.hasPrefix(".") ? String(line.dropFirst()) : line] = c
                    }
                }
            }
        }

        /// Catégorie d'un hôte : le domaine lui-même ou l'un de ses parents.
        public func category(of host: String) -> String? {
            var h = Substring(host.lowercased())
            while true {
                if let c = map[String(h)] { return c.isEmpty ? nil : c }   // "" : exception, pas de catégorie
                guard let dot = h.firstIndex(of: ".") else { return nil }
                h = h[h.index(after: dot)...]
            }
        }
    }

    /// Nombre de domaines dans les listes actives, sans charger les fichiers (pour la mini-fenêtre).
    public static func domainsOnLists(status: KidSafeStatus, catalog: Catalog, at date: Date = Date()) -> Int {
        status.domainCounts.values.reduce(0, +) + catalog.blockedDomains.count
            + catalog.blockedServices(at: date).reduce(0) { $0 + $1.domains.count }
    }

    // MARK: - Analyse du journal

    public struct Summary: Sendable {
        public var total: Int
        public var perHour: [(hour: Date, count: Int)]        // 24 dernières heures
        public var perDay: [(day: Date, count: Int)]          // 7 derniers jours
        public var topDomains: [(host: String, count: Int)]
        public var perCategory: [(name: String, count: Int)]
        public var recent: [BlockLog.Entry]
    }

    public static func summarize(_ entries: [BlockLog.Entry], index: CategoryIndex?, now: Date = Date(),
                                 calendar: Calendar = .current) -> Summary {
        let hourStart = calendar.dateInterval(of: .hour, for: now)!.start
        let dayStart = calendar.startOfDay(for: now)
        var hours = [Int](repeating: 0, count: 24), days = [Int](repeating: 0, count: 7)
        var byHost: [String: Int] = [:], byCat: [String: Int] = [:]
        for e in entries {
            let h = Int(floor(hourStart.timeIntervalSince(calendar.dateInterval(of: .hour, for: e.date)!.start) / 3600))
            if (0..<24).contains(h) { hours[23 - h] += 1 }
            if let d = calendar.dateComponents([.day], from: calendar.startOfDay(for: e.date), to: dayStart).day, (0..<7).contains(d) {
                days[6 - d] += 1
            }
            byHost[e.host, default: 0] += 1
            byCat[index?.category(of: e.host) ?? L("mon.cat.other"), default: 0] += 1
        }
        return Summary(
            total: entries.count,
            perHour: (0..<24).map { (calendar.date(byAdding: .hour, value: $0 - 23, to: hourStart)!, hours[$0]) },
            perDay: (0..<7).map { (calendar.date(byAdding: .day, value: $0 - 6, to: dayStart)!, days[$0]) },
            topDomains: byHost.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(15).map { ($0.key, $0.value) },
            perCategory: byCat.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            recent: Array(entries.sorted { $0.date > $1.date }.prefix(30)))
    }
}

public extension BlockLog {
    /// Toutes les entrées du journal (le fichier est plafonné à 5 Mo).
    static func all(_ file: URL) -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { parse(String($0)) }
    }
}
