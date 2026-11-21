import Foundation
import Testing
@testable import KidSafeCore

@Suite struct DomainNameTests {
    @Test(arguments: [
        ("Example.COM", "example.com"), ("*.example.com", "example.com"), (".example.com.", "example.com"),
        ("sub_domain.example.com", "sub_domain.example.com"), ("1.2.3.4", "1.2.3.4"), ("xn--bcher-kva.ch", "xn--bcher-kva.ch"),
    ])
    func valid(_ input: String, _ expected: String) {
        #expect(DomainName.normalize(input) == expected)
    }

    @Test(arguments: ["localhost", "com", "-bad.com", "bad-.com", "a..b.com", "exa mple.com", "bücher.ch",
                      "example.com/path", "1.2.3.999", "1.2.3", "", String(repeating: "a", count: 64) + ".com"])
    func invalid(_ input: String) {
        #expect(DomainName.normalize(input) == nil)
    }

    @Test func compactRemovesCoveredSubdomains() {
        let out = DomainName.compact(["example.com", "www.example.com", "a.b.example.com", "other.org", "cdn.other.net", "5.6.7.8"])
        #expect(out == ["example.com", "cdn.other.net", "other.org", "5.6.7.8"])   // tri par labels inversés : com < net < org
    }

    @Test func compactKeepsSiblingsAndLookalikes() {
        // `notexample.com` n'est pas un sous-domaine de `example.com`.
        let out = Set(DomainName.compact(["example.com", "notexample.com", "example.com.evil.org"]))
        #expect(out == ["example.com", "notexample.com", "example.com.evil.org"])
    }
}

@Suite struct ParserTests {
    @Test func adblockDomainRules() {
        let list = BlocklistParser.parse("""
        [Adblock Plus 2.0]
        ! Title: test
        ||ads.example.com^
        ||tracker.net^$important
        ||popup.org^$popup,document
        ||third.party.com^$third-party
        ||cdn.site.com/ads/*
        |http://legacy.com/banner
        /banner/*/img^
        example.com##.ad-banner
        ##.global-ad
        @@||ads.example.com^
        @@||safe.org^$document
        """)
        #expect(list.blocked == ["ads.example.com", "tracker.net", "popup.org"])
        #expect(list.allowed == ["ads.example.com", "safe.org"])
        #expect(list.stats.comments == 2)
        #expect(list.stats.unsupported == 6)
    }

    @Test func hostsFile() {
        let list = BlocklistParser.parse("""
        # StevenBlack-style
        127.0.0.1 localhost
        ::1 localhost ip6-localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 porn.example.com
        0.0.0.0\tbad.example.org  # commentaire
        127.0.0.1 one.com two.com\r
        0.0.0.0 not valid!
        """)
        #expect(list.blocked == ["porn.example.com", "bad.example.org", "one.com", "two.com"])
        #expect(list.stats.invalid == 2)   // `not`, `valid!`
    }

    @Test func plainDomainsUT1Style() {
        let list = BlocklistParser.parse("\u{FEFF}0-12kids.com\nWWW.Example.COM\n*.wild.net\n10.0.0.1\nhttp://url.com/x\n\n# fin\n")
        #expect(list.blocked == ["0-12kids.com", "www.example.com", "wild.net", "10.0.0.1"])
        #expect(list.stats.unsupported == 1)
        #expect(list.stats.comments == 1)
    }

    @Test func mixedFormatsMerge() {
        var a = BlocklistParser.parse("||a.com^\n")
        a.merge(BlocklistParser.parse("0.0.0.0 b.com\nc.com\n"))
        #expect(a.blocked == ["a.com", "b.com", "c.com"])
        #expect(a.stats.lines == 3)
    }
}

@Suite(.serialized) struct ActionsTests {
    init() { Localization.forcedLanguage = "fr" }

    @Test func categoryFileFormat() {
        var list = BlocklistParser.parse("||bad.com^\n||www.bad.com^\n||evil.org^\n9.9.9.9\n@@||ok.bad.com^\n@@||unrelated.net^\n")
        list.stats = .init()
        let text = PrivoxyActions.categoryFile(id: "Adult!", title: "Adulte {test}", sources: ["s"], list: list,
                                               date: Date(timeIntervalSince1970: 0))
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(body == ["{ +block{KidSafe : Adulte (test)} }", ".bad.com", ".evil.org", "9.9.9.9",
                         "{ -block }", ".ok.bad.com"])
        #expect(PrivoxyActions.fileName(forCategory: "Adult!") == "kidsafe-cat-adult-.action")
    }

    @Test func strictAndAllow() {
        #expect(PrivoxyActions.strictFile().hasSuffix("{ +block{KidSafe : mode strict, site non autorisé} }\n/\n"))
        let allow = PrivoxyActions.allowFile(domains: ["Wikipedia.org", "fr.wikipedia.org", "pas valide", "khanacademy.org"])
        let body = allow.split(separator: "\n").filter { !$0.hasPrefix("#") }
        #expect(body == ["{ -block }", ".khanacademy.org", ".wikipedia.org"])
    }
}

@Suite struct ConfigEditorTests {
    static let config = """
    confdir /usr/local/etc/privoxy
    actionsfile match-all.action
    actionsfile default.action
    actionsfile user.action
    filterfile default.filter
    actionsfile easylist.script.action
    filterfile easylist.script.filter
    toggle  1
    enable-remote-toggle 1
    #enable-edit-actions 0

    """

    @Test func insertsBeforeUserActionAndHardens() {
        let out = PrivoxyConfigEditor.apply(actionFiles: ["kidsafe-cat-adult.action", "kidsafe-allow.action"], to: Self.config)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let begin = lines.firstIndex(of: PrivoxyConfigEditor.beginMarker)!
        #expect(lines[begin - 1] == "actionsfile default.action")
        #expect(lines[begin + 1] == "actionsfile kidsafe-cat-adult.action")
        #expect(lines[begin + 2] == "actionsfile kidsafe-allow.action")
        #expect(lines.contains("enable-remote-toggle 0"))
        #expect(lines.contains("#KidSafe-désactivé# enable-remote-toggle 1"))
        #expect(lines.contains("#KidSafe-désactivé# toggle  1"))
        #expect(lines.contains("#enable-edit-actions 0"))   // commentaire d'origine intact
        let user = lines.firstIndex(of: "actionsfile user.action")!
        #expect(user > begin)
        #expect(PrivoxyConfigEditor.managedActionFiles(in: out) == ["kidsafe-cat-adult.action", "kidsafe-allow.action"])
    }

    @Test func idempotentAndReversible() {
        let once = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: Self.config)
        let twice = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: once)
        #expect(once == twice)
        let changed = PrivoxyConfigEditor.apply(actionFiles: ["b.action"], to: once)
        #expect(PrivoxyConfigEditor.managedActionFiles(in: changed) == ["b.action"])
        #expect(PrivoxyConfigEditor.remove(from: changed) == Self.config)
    }

    @Test func removesLegacyBlocklistLines() {
        let out = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: Self.config,
                                            options: .init(harden: false, removeLegacyBlocklist: true))
        #expect(!out.contains(".script."))
        #expect(out.contains("enable-remote-toggle 1"))
    }

    @Test func noUserActionFallsBackToLastActionsfileThenEnd() {
        let a = PrivoxyConfigEditor.apply(actionFiles: ["x.action"], to: "actionsfile default.action\nlogdir /var\n",
                                          options: .init(harden: false))
        #expect(a == "actionsfile default.action\n\(PrivoxyConfigEditor.beginMarker)\nactionsfile x.action\n\(PrivoxyConfigEditor.endMarker)\nlogdir /var\n")
        let b = PrivoxyConfigEditor.apply(actionFiles: ["x.action"], to: "logdir /var\n", options: .init(harden: false))
        #expect(b.hasPrefix("logdir /var\n\(PrivoxyConfigEditor.beginMarker)"))
    }
}

@Suite struct InstallerTests {
    func tempConfDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ConfigEditorTests.config.write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func installReplaceAndUninstall() throws {
        let dir = try tempConfDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inst = PrivoxyInstaller(confDir: dir)

        let r1 = try inst.install(.init(files: [("kidsafe-cat-a.action", "A"), ("kidsafe-cat-b.action", "B")], options: .init()))
        #expect(r1.written == ["kidsafe-cat-a.action", "kidsafe-cat-b.action"])
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("kidsafe-cat-a.action").path)[.posixPermissions] as? Int
        #expect(perms == 0o644)

        // Catégorie b décochée : son fichier disparaît.
        let r2 = try inst.install(.init(files: [("kidsafe-cat-a.action", "A2")], options: .init()))
        #expect(r2.removed == ["kidsafe-cat-b.action"])
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("kidsafe-cat-b.action").path))

        _ = try inst.uninstall()
        let config = try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)
        #expect(config == ConfigEditorTests.config)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("kidsafe") || $0.hasPrefix(".kidsafe") }
        #expect(left.isEmpty)
    }

    @Test func rollbackWhenConfigTestFails() throws {
        let dir = try tempConfDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "ancien".write(to: dir.appendingPathComponent("kidsafe-cat-a.action"), atomically: true, encoding: .utf8)
        // Faux binaire Privoxy qui refuse toute configuration.
        let fake = dir.appendingPathComponent("fake-privoxy")
        try "#!/bin/sh\necho 'Fatal error: bad action'\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let inst = PrivoxyInstaller(confDir: dir, privoxyBinary: fake)
        #expect(throws: KidSafeError.self) {
            try inst.install(.init(files: [("kidsafe-cat-a.action", "nouveau"), ("kidsafe-cat-c.action", "C")], options: .init()))
        }
        #expect(try String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8) == ConfigEditorTests.config)
        #expect(try String(contentsOf: dir.appendingPathComponent("kidsafe-cat-a.action"), encoding: .utf8) == "ancien")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("kidsafe-cat-c.action").path))
    }
}

@Suite struct UpdaterTests {
    @Test func offlineSourcesWithCacheAndFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("list.txt")
        try "||bad.com^\n0.0.0.0 worse.org\n".write(to: src, atomically: true, encoding: .utf8)

        let catalog = Catalog(categories: [
            .init(id: "a", name: "A", enabled: true, sources: [.init(url: src.absoluteString)]),
            .init(id: "off", name: "Off", enabled: false, sources: [.init(url: src.absoluteString)]),
            .init(id: "broken", name: "Broken", enabled: true, sources: [.init(url: "http://insecure.example/list.txt")]),
        ], allowlist: ["good.org"])
        let updater = BlocklistUpdater(fetcher: SourceFetcher(cacheDir: dir.appendingPathComponent("cache")))

        let r = await updater.prepare(catalog, existingConfDir: nil)
        #expect(r.plan.files.map(\.name) == ["kidsafe-cat-a.action", "kidsafe-block.action", "kidsafe-services.action", "kidsafe-allow.action"])
        #expect(r.categories.first?.blockedCount == 2)
        #expect(r.failed.map(\.id) == ["broken"])

        // Source supprimée : la copie en cache prend le relais.
        try FileManager.default.removeItem(at: src)
        let r2 = await updater.prepare(catalog, existingConfDir: nil)
        #expect(r2.categories.first?.blockedCount == 2)
        #expect(r2.categories.first?.warnings.isEmpty == false)
    }

    @Test func strictModeIgnoresCategories() async {
        let catalog = Catalog(categories: Catalog.default.categories, allowlist: ["wikipedia.org"], strictMode: true)
        let r = await BlocklistUpdater(fetcher: SourceFetcher(cacheDir: FileManager.default.temporaryDirectory))
            .prepare(catalog, existingConfDir: nil)
        #expect(r.plan.files.map(\.name) == ["kidsafe-strict.action", "kidsafe-block.action", "kidsafe-services.action", "kidsafe-allow.action"])
    }
}

@Suite struct CatalogTests {
    @Test func onlyAdultEnabledByDefault() {
        #expect(Catalog.default.categories.filter(\.enabled).map(\.id) == ["adult"])
        #expect(Catalog.default.categories.first { $0.id == "adult-ut1" }?.warning != nil)
        #expect(Set(Catalog.library.map(\.id)).isDisjoint(with: Catalog.default.categories.map(\.id)))
    }

    @Test func addEnableRemoveCustomList() throws {
        var c = Catalog.default
        try c.addCustomList(id: "EasyList", name: "EasyList", sources: [.init(url: "https://easylist.to/easylist/easylist.txt")])
        #expect(c.categories.last?.id == "easylist")
        #expect(c.categories.last?.enabled == true && c.categories.last?.custom == true)
        #expect(throws: Catalog.EditError.self) { try c.addCustomList(id: "easylist", name: "x", sources: []) }
        #expect(throws: Catalog.EditError.self) { try c.removeCustomList("adult") }
        try c.setEnabled("easylist", false)
        #expect(c.categories.last?.enabled == false)
        try c.removeCustomList("easylist")
        #expect(c == Catalog.default)
    }

    @Test func oldCatalogFilesStillDecode() throws {
        let json = #"{"categories":[{"id":"a","name":"A","enabled":true,"sources":[]}],"allowlist":[],"strictMode":false,"hardenPrivoxy":true}"#
        let c = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        #expect(c.categories.first?.warning == nil)
    }
}

@Suite(.serialized) struct LocalizationTests {
    @Test func frenchAndEnglish() {
        defer { Localization.forcedLanguage = "fr" }
        Localization.forcedLanguage = "fr"
        #expect(L("category.adult") == "Contenus pour adultes")
        #expect(L("error.unknownID", "x") == "Liste inconnue : x")
        Localization.forcedLanguage = "en"
        #expect(L("category.adult") == "Adult content")
        #expect(Catalog.default.categories[0].displayName == "Adult content")
        #expect(Catalog.default.categories[1].displayWarning?.hasPrefix("Very large list") == true)
        #expect(Catalog.library.first?.name == "EasyList (ads, domain rules only)")
    }

    @Test func customNamesAreNotTranslated() {
        let c = Catalog.Category(id: "adult", name: "Ma liste", enabled: true, sources: [], custom: true)
        #expect(c.displayName == "Ma liste")
    }
}

@Suite struct LocalImportTests {
    @Test func importCopiesAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Ma liste.txt")
        try "0.0.0.0 bad.com\n||worse.org^\n".write(to: src, atomically: true, encoding: .utf8)
        let empty = dir.appendingPathComponent("vide.txt")
        try "# rien\n".write(to: empty, atomically: true, encoding: .utf8)
        let listsDir = dir.appendingPathComponent("lists")

        var c = Catalog.default
        let id = c.uniqueID(for: "Ma liste à moi")
        #expect(id == "ma-liste-a-moi")
        let n = try c.addLocalList(file: src, id: id, name: "Ma liste à moi", listsDir: listsDir)
        #expect(n == 2)
        let source = try #require(c.categories.last?.sources.first)
        #expect(source.url.hasPrefix("file://") && source.url.hasSuffix("/lists/ma-liste-a-moi.txt"))
        try FileManager.default.removeItem(at: src)   // la copie survit à l'original
        #expect(FileManager.default.fileExists(atPath: listsDir.appendingPathComponent("ma-liste-a-moi.txt").path))
        #expect(throws: LocalListImporter.ImportError.self) {
            try c.addLocalList(file: empty, id: "vide", name: "Vide", listsDir: listsDir)
        }

        let engine = KidSafeEngine(paths: KidSafePaths(supportDir: dir))
        try engine.removeCustomList(id, from: &c)
        #expect(!FileManager.default.fileExists(atPath: listsDir.appendingPathComponent("ma-liste-a-moi.txt").path))
    }
}

/// Calendrier fixe pour des tests indépendants du fuseau de la machine.
private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
/// 2026-11-16 est un lundi.
private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: 15 + day, hour: h, minute: m))!
}

@Suite struct ScheduleTests {
    @Test func dayWindow() {
        let w = TimeWindow(days: [3], start: 14 * 60, end: 18 * 60)   // mercredi 14 h–18 h
        #expect(w.contains(at(3, 14), calendar: utc))
        #expect(w.contains(at(3, 17, 59), calendar: utc))
        #expect(!w.contains(at(3, 18), calendar: utc))
        #expect(!w.contains(at(2, 15), calendar: utc))
    }

    @Test func overnightWindowSpillsIntoNextDay() {
        let w = TimeWindow(days: [5], start: 21 * 60, end: 7 * 60)    // vendredi 21 h → samedi 7 h
        #expect(w.contains(at(5, 22), calendar: utc))
        #expect(w.contains(at(6, 6, 30), calendar: utc))
        #expect(!w.contains(at(6, 7), calendar: utc))
        #expect(!w.contains(at(5, 6), calendar: utc))                  // vendredi matin : la nuit de jeudi n'est pas cochée
        #expect(TimeWindow(days: [7], start: 0, end: 0).contains(at(7, 12), calendar: utc))   // dimanche toute la journée
    }

    @Test func policies() {
        let night = TimeWindow(days: TimeWindow.allDays, start: 21 * 60, end: 7 * 60)
        #expect(!ServicePolicy().isBlocked(at: at(1, 12), calendar: utc))
        #expect(ServicePolicy(mode: .blocked).isBlocked(at: at(1, 12), calendar: utc))
        #expect(ServicePolicy(mode: .blockedDuring, windows: [night]).isBlocked(at: at(1, 23), calendar: utc))
        #expect(!ServicePolicy(mode: .blockedDuring, windows: [night]).isBlocked(at: at(1, 12), calendar: utc))
        let wed = TimeWindow(days: [3], start: 14 * 60, end: 18 * 60)
        #expect(!ServicePolicy(mode: .allowedOnlyDuring, windows: [wed]).isBlocked(at: at(3, 15), calendar: utc))
        #expect(ServicePolicy(mode: .allowedOnlyDuring, windows: [wed]).isBlocked(at: at(4, 15), calendar: utc))
        #expect(ServicePolicy(mode: .allowedOnlyDuring, windows: []).isBlocked(at: at(4, 15), calendar: utc))
    }

    @Test func servicesFileListsBlockedServicesOnly() {
        var c = Catalog.default
        c.services["tiktok"] = ServicePolicy(mode: .blocked)
        c.services["youtube"] = ServicePolicy(mode: .blockedDuring, windows: [TimeWindow(days: [1], start: 8 * 60, end: 12 * 60)])
        #expect(c.blockedServices(at: at(1, 9), calendar: utc).map(\.id) == ["tiktok", "youtube"])
        #expect(c.blockedServices(at: at(1, 13), calendar: utc).map(\.id) == ["tiktok"])
        let text = PrivoxyActions.servicesFile(blocked: c.blockedServices(at: at(1, 13), calendar: utc))
        #expect(text.contains("{ +block{KidSafe : TikTok} }"))
        #expect(text.contains("\n.tiktok.com\n"))
        #expect(!text.contains("youtube"))
        #expect(SocialService.all.allSatisfy { s in s.domains.allSatisfy { DomainName.normalize($0) == $0 } })
    }
}

@Suite struct PasswordAndDomainTests {
    @Test func passwordHash() {
        let h = PasswordHash.make("Licorne-42", iterations: 1000)
        #expect(h.verify("Licorne-42"))
        #expect(!h.verify("licorne-42"))
        #expect(PasswordHash.make("Licorne-42", iterations: 1000).salt != h.salt)
    }

    @Test(arguments: [("https://www.TikTok.com/@user?x=1", "www.tiktok.com"), ("roblox.com", "roblox.com"),
                      ("http://user@site.org:8080/path", "site.org"), ("  exemple.fr/ ", "exemple.fr")])
    func normalizeUserInput(_ raw: String, _ expected: String) {
        #expect(Catalog.normalizeUserDomain(raw) == expected)
    }

    @Test func blockAndAllowAreExclusive() throws {
        var c = Catalog.default
        try c.addBlockedDomain("roblox.com")
        try c.addAllowedDomain("https://roblox.com/")
        #expect(c.blockedDomains.isEmpty && c.allowlist == ["roblox.com"])
        try c.addBlockedDomain("roblox.com")
        #expect(c.blockedDomains == ["roblox.com"] && c.allowlist.isEmpty)
        #expect(throws: Catalog.DomainError.self) { try c.addBlockedDomain("pas un domaine") }
    }

    @Test func newFieldsRoundTripAndDefaults() throws {
        var c = Catalog.default
        c.services["x"] = ServicePolicy(mode: .blocked)
        c.refreshHours = 6
        c.filteringEnabled = false
        c.parentPassword = PasswordHash.make("a", iterations: 1000)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Catalog.self, from: data) == c)
        #expect(Catalog.default.refreshHours == 24 && Catalog.default.filteringEnabled && Catalog.default.parentPassword == nil)
    }
}

@Suite struct PauseTests {
    @Test func pauseKeepsFilesAndResumeRestores() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-pause-\(UUID().uuidString)")
        let conf = dir.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ConfigEditorTests.config.write(to: conf.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let src = dir.appendingPathComponent("l.txt")
        try "bad.com\n".write(to: src, atomically: true, encoding: .utf8)

        let engine = KidSafeEngine(paths: KidSafePaths(supportDir: dir.appendingPathComponent("support")))
        let inst = PrivoxyInstaller(confDir: conf)
        var c = Catalog(categories: [.init(id: "a", name: "A", enabled: true, sources: [.init(url: src.absoluteString)])])
        c.services["tiktok"] = ServicePolicy(mode: .blocked)
        _ = try await engine.apply(c, installer: inst)
        let cfg = { try String(contentsOf: conf.appendingPathComponent("config"), encoding: .utf8) }
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try cfg()).contains("kidsafe-services.action"))

        // Changement de plage : seul le fichier des réseaux change.
        c.services["tiktok"] = ServicePolicy(mode: .allowed)
        #expect(try engine.refreshServices(c, installer: inst))
        #expect(try !engine.refreshServices(c, installer: inst))
        #expect(!(try String(contentsOf: conf.appendingPathComponent("kidsafe-services.action"), encoding: .utf8)).contains("tiktok"))

        c.filteringEnabled = false
        try engine.pause(c, installer: inst)
        #expect(inst.isPaused())
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try cfg()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: conf.appendingPathComponent("kidsafe-cat-a.action").path))
        #expect(try !engine.refreshServices(c, installer: inst))

        c.filteringEnabled = true
        _ = try await engine.apply(c, installer: inst)
        #expect(!inst.isPaused())
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try cfg()).first == "kidsafe-cat-a.action")
    }
}

@Suite struct BundledPrivoxyTests {
    @Test func adaptsTemplate() {
        let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/KidSafe/privoxy")
        let out = BundledPrivoxy.adapt("confdir .\nlogdir .\n#listen-address [::1]:8118\nlisten-address  127.0.0.1:8118\ntoggle 1", dir: dir)
        #expect(out == "confdir \(dir.path)\nlogdir \(dir.path)/log\n#listen-address [::1]:8118\nlisten-address  127.0.0.1:\(BundledPrivoxy.port)\ntoggle 1")
    }

    @Test func prepareCopiesAndKeepsKidSafeBlock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Faux KidSafe.app : Helpers/privoxy + Resources/privoxy-conf
        let app = root.appendingPathComponent("KidSafe.app/Contents")
        let conf = app.appendingPathComponent("Resources/privoxy-conf")
        try FileManager.default.createDirectory(at: conf.appendingPathComponent("templates"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: app.appendingPathComponent("Helpers/privoxy"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("Helpers/privoxy").path)
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleVersion</key><string>1</string></dict></plist>"
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        for f in ["match-all.action", "default.action", "default.filter", "trust", "user.action", "user.filter", "VERSION", "templates/blocked"] {
            try f.write(to: conf.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        try "confdir .\nlogdir .\nactionsfile user.action\nlisten-address 127.0.0.1:8118\n".write(to: conf.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: root.appendingPathComponent("KidSafe.app")))
        let support = root.appendingPathComponent("support")

        let inst = try #require(try BundledPrivoxy.prepare(bundle: bundle, supportDir: support))
        #expect(FileManager.default.isExecutableFile(atPath: inst.privoxyBinary!.path))
        var cfg = try String(contentsOf: inst.configFile, encoding: .utf8)
        #expect(cfg.contains("listen-address  127.0.0.1:\(BundledPrivoxy.port)"))

        // KidSafe installe ses listes, puis une nouvelle version de l'app réinstalle Privoxy.
        cfg = PrivoxyConfigEditor.apply(actionFiles: ["kidsafe-cat-adult.action"], to: cfg)
        try cfg.write(to: inst.configFile, atomically: true, encoding: .utf8)
        try "2".write(to: support.appendingPathComponent("privoxy/.kidsafe-bundle"), atomically: true, encoding: .utf8)
        let again = try #require(try BundledPrivoxy.prepare(bundle: bundle, supportDir: support))
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try String(contentsOf: again.configFile, encoding: .utf8)) == ["kidsafe-cat-adult.action"])
    }
}
