import Foundation

/// Remplace privoxy-blocklist.sh + blocklist2privoxy.sh :
/// télécharge les sources des catégories cochées, les convertit et prépare l'installation.
public struct BlocklistUpdater: Sendable {
    public var fetcher: SourceFetcher
    public init(fetcher: SourceFetcher) { self.fetcher = fetcher }

    public struct CategoryResult: Sendable {
        public var id: String
        public var fileName: String
        public var blockedCount: Int
        public var stats: ParsedBlocklist.Stats
        public var warnings: [String]
        /// Dates et état du téléchargement (`delta` est calculé par le moteur).
        public var list = ListStatus()
        /// Liste assez lourde pour ralentir Privoxy (voir `Catalog.heavyListThreshold`).
        public var heavy: Bool { blockedCount > Catalog.heavyListThreshold }
    }

    public struct Result: Sendable {
        public var plan: PrivoxyInstaller.Plan
        public var categories: [CategoryResult]
        /// Catégories cochées dont aucune source n'a pu être lue (ni en ligne, ni en cache).
        public var failed: [(id: String, error: String)]
    }

    /// Une catégorie en échec n'est pas retirée : si son fichier existe déjà dans `confDir`,
    /// il est conservé tel quel plutôt que de laisser l'enfant sans protection.
    public func prepare(_ catalog: Catalog, existingConfDir: URL?, date: Date = Date(),
                        progress: (@Sendable (String, ListProgress) -> Void)? = nil) async -> Result {
        var files: [(name: String, content: String)] = []
        var results: [CategoryResult] = []
        var failed: [(String, String)] = []

        if catalog.strictMode {
            files.append((PrivoxyActions.strictFileName, PrivoxyActions.strictFile()))
        } else {
            for cat in catalog.categories where cat.enabled {
                let name = PrivoxyActions.fileName(forCategory: cat.id)
                var merged = ParsedBlocklist()
                var warnings: [String] = []
                var ok = 0
                var list = ListStatus(checked: date)
                var anyChanged = false
                let id = cat.id
                for src in cat.sources {
                    do {
                        progress?(id, .downloading(received: 0, expected: 0))
                        var bytes: SourceFetcher.Progress?
                        if let progress {
                            bytes = { received, expected in progress(id, .downloading(received: received, expected: expected)) }
                        }
                        let fetched = try await fetcher.fetch(src, progress: bytes)
                        if let w = fetched.warning { warnings.append(w) }
                        if fetched.fromCache {
                            // La plus ancienne copie utilisée ; la raison est gardée pour le survol.
                            list.cacheUsed = min(list.cacheUsed ?? .distantFuture, fetched.dataDate ?? .distantPast)
                            list.error = fetched.warning
                            list.checked = nil
                        } else if !fetched.unchanged {
                            anyChanged = true
                        }
                        if let c = fetched.changed { list.changed = max(list.changed ?? .distantPast, c) }
                        progress?(id, .converting)
                        merged.merge(BlocklistParser.parse(fetched.data))
                        ok += 1
                    } catch {
                        warnings.append("\(error)")
                    }
                }
                list.changedNow = anyChanged
                if ok > 0, !merged.blocked.isEmpty {
                    if merged.blocked.count > Catalog.heavyListThreshold {
                        warnings.append(cat.displayWarning ?? L("warning.heavy.generic", formatCount(merged.blocked.count)))
                    }
                    let content = PrivoxyActions.categoryFile(id: cat.id, title: cat.displayName,
                                                              sources: cat.sources.map(\.url), list: merged)
                    files.append((name, content))
                    results.append(CategoryResult(id: cat.id, fileName: name, blockedCount: merged.blocked.count,
                                                  stats: merged.stats, warnings: warnings, list: list))
                } else if let dir = existingConfDir,
                          let previous = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) {
                    files.append((name, previous))
                    failed.append((cat.id, (warnings + [L("warning.previousKept")]).joined(separator: " ; ")))
                } else {
                    failed.append((cat.id, warnings.isEmpty ? L("warning.noDomains") : warnings.joined(separator: " ; ")))
                }
            }
        }
        // Domaines perso et réseaux sociaux : toujours présents (éventuellement vides), pour que
        // les changements de plage horaire ne réécrivent qu'un fichier, sans toucher à la config.
        files.append((PrivoxyActions.customBlockFileName, PrivoxyActions.customBlockFile(domains: catalog.blockedDomains)))
        files.append((PrivoxyActions.servicesFileName, PrivoxyActions.servicesFile(blocked: catalog.blockedServices(at: date))))
        // La liste blanche est toujours chargée en dernier : elle l'emporte.
        files.append((PrivoxyActions.allowFileName, PrivoxyActions.allowFile(domains: catalog.allowlist)))

        let options = PrivoxyConfigEditor.Options(catalog: catalog)
        return Result(plan: .init(files: files, options: options), categories: results, failed: failed)
    }
}
