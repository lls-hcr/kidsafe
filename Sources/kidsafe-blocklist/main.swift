import Foundation
import KidSafeCore

// kidsafe-blocklist : remplace privoxy-blocklist.sh et blocklist2privoxy.sh.
// Langue : celle du système, ou KIDSAFE_LANG=fr|en.

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

func log(_ msg: String) { FileHandle.standardError.write(Data((msg + "\n").utf8)) }

struct Args {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valued: Set<String>) {
        var it = raw.makeIterator()
        while let a = it.next() {
            if valued.contains(a) {
                guard let v = it.next() else { fail(L("cli.missingValue", a) + "\n\n" + L("cli.usage")) }
                values[a] = v
            } else if a.hasPrefix("-") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }
}

func installer(_ args: Args) -> PrivoxyInstaller {
    if let dir = args.values["--conf-dir"] {
        let bin = args.values["--privoxy"].map { URL(fileURLWithPath: $0) } ?? PrivoxyInstaller.detect()?.privoxyBinary
        return PrivoxyInstaller(confDir: URL(fileURLWithPath: dir), privoxyBinary: bin)
    }
    guard var found = PrivoxyInstaller.detect() else { fail(L("cli.privoxyNotFound")) }
    if let bin = args.values["--privoxy"] { found.privoxyBinary = URL(fileURLWithPath: bin) }
    return found
}

/// Sans --catalog, la CLI partage le catalogue de l'app.
func catalogURL(_ args: Args) -> URL {
    args.values["--catalog"].map { URL(fileURLWithPath: $0) } ?? KidSafePaths.user.catalogFile
}

func loadCatalog(_ url: URL) -> Catalog {
    if url == KidSafePaths.user.catalogFile {
        do { return try KidSafeEngine().loadCatalog() } catch { fail(L("cli.catalogUnreadable", "\(error)")) }
    }
    do { return try Catalog.load(from: url) } catch { fail(L("cli.catalogUnreadable", "\(error)")) }
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { fail(L("cli.usage")) }
let catalogOptions: Set<String> = ["--catalog", "--conf-dir", "--privoxy", "--cache-dir", "--from-library",
                                   "--id", "--name", "--url", "--member", "--file", "-o"]

switch argv[1] {
case "convert":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    guard !args.positional.isEmpty else { fail(L("cli.usage")) }
    var merged = ParsedBlocklist()
    for path in args.positional {
        guard let data = FileManager.default.contents(atPath: path) else { fail(L("error.localUnreadable", path)) }
        merged.merge(BlocklistParser.parse(data))
    }
    let id = args.values["--id"] ?? "custom"
    let text = PrivoxyActions.categoryFile(id: id, title: args.values["--name"] ?? id, sources: args.positional, list: merged)
    if let out = args.values["-o"] {
        do { try text.write(toFile: out, atomically: true, encoding: .utf8) } catch { fail("\(error)") }
    } else {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
    let s = merged.stats
    log(L("cli.convert.stats", formatCount(s.lines), formatCount(merged.blocked.count), formatCount(merged.allowed.count),
          formatCount(s.unsupported), formatCount(s.invalid), formatCount(s.comments)))

case "update":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    let catalog = loadCatalog(catalogURL(args))
    let inst = installer(args)
    var paths = KidSafePaths.user
    if let cache = args.values["--cache-dir"] { paths.supportDir = URL(fileURLWithPath: cache) }
    let updater = BlocklistUpdater(fetcher: SourceFetcher(cacheDir: paths.cacheDir))
    let prepared = await updater.prepare(catalog, existingConfDir: inst.confDir)

    for c in prepared.categories {
        log(L("cli.update.category", c.id, formatCount(c.blockedCount), formatCount(c.stats.unsupported), c.fileName))
        for w in c.warnings { log("  ⚠︎ \(w)") }
    }
    for f in prepared.failed { log("✗ \(f.id) : \(f.error)") }

    var plan = prepared.plan
    if args.flags.contains("--remove-legacy") { plan.options.removeLegacyBlocklist = true }
    if args.flags.contains("--dry-run") {
        log(L("cli.update.dryRun", inst.confDir.path))
        for f in plan.files { log("  \(f.name) (\(formatCount(f.content.utf8.count)) o)") }
        exit(0)
    }
    do {
        let r = try inst.install(plan)
        log(L("cli.update.installed", inst.confDir.path, r.written.joined(separator: ", ")))
        if !r.removed.isEmpty { log(L("cli.update.removed", r.removed.joined(separator: ", "))) }
        log(r.configTested ? L("cli.update.tested") : L("cli.update.notTested"))
    } catch {
        fail(L("cli.update.failed", "\(error)"))
    }
    exit(prepared.failed.isEmpty ? 0 : 2)

case "uninstall":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    do {
        let r = try installer(args).uninstall()
        log(L("cli.uninstall.done", r.removed.isEmpty ? "—" : r.removed.joined(separator: ", ")))
    } catch { fail("\(error)") }

case "default-catalog":
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try! enc.encode(Catalog.default))
    print()

case "lists", "enable", "disable", "add-list", "remove-list":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    let catURL = catalogURL(args)
    var catalog = loadCatalog(catURL)
    let engine = KidSafeEngine()
    do {
        switch argv[1] {
        case "lists":
            for c in catalog.categories {
                let tags = (c.custom == true ? "  " + L("cli.tag.custom") : "") + (c.warning != nil ? "  ⚠︎ " + L("cli.tag.heavy") : "")
                print("\(c.enabled ? "[x]" : "[ ]") \(c.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(c.displayName)\(tags)")
            }
            exit(0)
        case "enable", "disable":
            guard let id = args.positional.first else { fail(L("cli.usage")) }
            if argv[1] == "enable", let w = catalog.categories.first(where: { $0.id == id })?.displayWarning, !args.flags.contains("--yes") {
                fail("⚠︎ \(w)\n" + L("cli.confirmWithYes"), code: 3)
            }
            try catalog.setEnabled(id, argv[1] == "enable")
        case "add-list":
            if let libID = args.values["--from-library"] {
                guard let preset = Catalog.library.first(where: { $0.id == libID }) else { fail(L("error.unknownID", libID)) }
                try catalog.addCustomList(id: preset.id, name: preset.name, sources: preset.sources, warning: preset.warning)
            } else if let file = args.values["--file"] {
                let url = URL(fileURLWithPath: file)
                let name = args.values["--name"] ?? url.deletingPathExtension().lastPathComponent
                let id = args.values["--id"] ?? catalog.uniqueID(for: name)
                let n = try catalog.addLocalList(file: url, id: id, name: name, listsDir: engine.paths.listsDir)
                log(L("cli.addList.imported", formatCount(n)))
            } else {
                guard let name = args.values["--name"], let url = args.values["--url"] else { fail(L("cli.usage")) }
                guard url.lowercased().hasPrefix("https://") || url.lowercased().hasPrefix("file://") else { fail(L("error.insecureURL", url)) }
                let id = args.values["--id"] ?? catalog.uniqueID(for: name)
                try catalog.addCustomList(id: id, name: name, sources: [.init(url: url, archiveMember: args.values["--member"])])
            }
        default:
            guard let id = args.positional.first else { fail(L("cli.usage")) }
            try engine.removeCustomList(id, from: &catalog)
        }
        try catalog.save(to: catURL)
        log(L("cli.catalogSaved", catURL.path))
    } catch { fail("\(error)") }

case "pause", "resume":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    let catURL = catalogURL(args)
    var catalog = loadCatalog(catURL)
    if catalog.parentPassword != nil {
        guard let pw = String(validatingCString: getpass(L("app.lock.title") + " : ")), catalog.parentPassword!.verify(pw) else {
            fail(L("cli.badPassword"))
        }
    }
    let inst = installer(args)
    catalog.filteringEnabled = argv[1] == "resume"
    catalog.pausedUntil = nil
    do {
        try catalog.save(to: catURL)
        if catalog.filteringEnabled {
            _ = try await KidSafeEngine().apply(catalog, installer: inst)
            log(L("cli.resumed"))
        } else {
            try KidSafeEngine().pause(catalog, installer: inst)
            log(L("cli.paused"))
        }
    } catch { fail("\(error)") }

case "block", "allow":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    guard let raw = args.positional.first else { fail(L("cli.usage")) }
    let catURL = catalogURL(args)
    var catalog = loadCatalog(catURL)
    do {
        let d = argv[1] == "block" ? try catalog.addBlockedDomain(raw) : try catalog.addAllowedDomain(raw)
        try catalog.save(to: catURL)
        log("\(argv[1] == "block" ? "⛔︎" : "✓") \(d) — " + L("cli.catalogSaved", catURL.path))
    } catch { fail("\(error)") }

case "dashboard":
    // Page détaillée du moniteur, générée depuis le Terminal.
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    let inst = installer(args)
    let e = SystemStatus.listenAddress(configFile: inst.configFile)
    let counters = await Monitor.counters(host: e.host, port: e.port)
    let catalog = loadCatalog(catalogURL(args))
    let entries = BlockLog.all(BlockLog.logFile(confDir: inst.confDir))
    let index = Monitor.CategoryIndex(confDir: inst.confDir)
    let html = Dashboard.html(.init(counters: counters, domainsOnLists: index.domainCount, summary: Monitor.summarize(entries, index: index),
                                    logEnabled: !entries.isEmpty || catalog.recordsBlocks, version: "cli"))
    let out = args.values["-o"] ?? "kidsafe-dashboard.html"
    do { try html.write(toFile: out, atomically: true, encoding: .utf8); log(out) } catch { fail("\(error)") }

case "guide":
    let args = Args(argv.dropFirst(2), valued: catalogOptions)
    guard let html = UserGuide.html(version: "cli") else { fail("guide") }
    let out = args.values["-o"] ?? "kidsafe-guide.html"
    do { try html.write(toFile: out, atomically: true, encoding: .utf8); log(out) } catch { fail("\(error)") }

case "library":
    for c in Catalog.library {
        print("\(c.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(c.name)  [\(c.sources.first?.license ?? "?")]")
    }

case "-h", "--help", "help":
    print(L("cli.usage"))

default:
    fail(L("cli.usage"))
}
