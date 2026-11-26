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
        #expect(lines.contains("enforce-blocks 1"))
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

    @Test func defaultListsAreGroupedWithLevels() {
        let c = Catalog.default
        #expect(c.version == Catalog.currentVersion)
        #expect(c.categories.map(\.id) == ["adult", "adult-oisd", "adult-ut1", "ads", "ads-oisd", "security", "bypass"])
        #expect(c.categories.allSatisfy { $0.group != nil && $0.custom != true })
        #expect(c.categories.filter { $0.level != nil }.map(\.id) == ["ads", "security"])
        #expect(c.categories.first { $0.id == "ads" }?.sources.first?.url.hasSuffix("/pro.mini-onlydomains.txt") == true)
        // Les thèmes (jeux d'argent, violence…) ne sont plus dans la fenêtre par défaut : on les ajoute depuis le menu.
        #expect(Catalog.themeLibrary.map(\.id).contains("gambling") && Catalog.library.allSatisfy { $0.custom == true })
        #expect(!Catalog.library.contains { $0.id.hasPrefix("blp-") })
    }

    @Test func levelChangesSourcesAndWarning() throws {
        var c = Catalog.default
        try c.setLevel("security", .strong)
        var sec = try #require(c.categories.first { $0.id == "security" })
        #expect(sec.level == .strong && sec.sources.map(\.url) == [
            "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt"])
        #expect(sec.warning == Catalog.heavyTIFWarning)
        try c.setLevel("security", .normal)
        sec = try #require(c.categories.first { $0.id == "security" })
        #expect(sec.sources.first?.url.hasSuffix("/tif.medium-onlydomains.txt") == true && sec.warning == nil)
        try c.setLevel("ads", .strong)
        #expect(c.categories.first { $0.id == "ads" }?.sources.first?.url.hasSuffix("/pro.plus-onlydomains.txt") == true)
        #expect(throws: Catalog.EditError.self) { try c.setLevel("adult", .strong) }
        #expect(throws: Catalog.EditError.self) { try c.setLevel("inconnue", .light) }
    }

    /// Catalogue enregistré par la 0.7.3 : rien ne se décoche, les thèmes cochés deviennent des listes ajoutées.
    @Test func migratesCatalogFrom073() throws {
        let hz = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/"
        let ut1 = "https://dsi.ut-capitole.fr/blacklists/download/"
        func cat(_ id: String, _ on: Bool, _ url: String, custom: Bool? = nil) -> Catalog.Category {
            .init(id: id, name: id, enabled: on, sources: [.init(url: url)], custom: custom)
        }
        var old = Catalog(categories: [
            cat("adult", true, hz + "nsfw-onlydomains.txt"), cat("adult-ut1", false, ut1 + "adult.tar.gz"),
            cat("bypass", false, hz + "doh-vpn-proxy-bypass-onlydomains.txt"), cat("security", true, hz + "tif.mini-onlydomains.txt"),
            cat("gambling", true, ut1 + "gambling.tar.gz"), cat("violence", false, ut1 + "agressif.tar.gz"),
            cat("ads", true, hz + "pro.mini-onlydomains.txt"),
            cat("easylist", true, "https://easylist.to/easylist/easylist.txt", custom: true),
            cat("blp-scam", false, "https://blocklistproject.github.io/Lists/alt-version/scam-nl.txt", custom: true),
        ], allowlist: ["wikipedia.org"])
        let data = try JSONEncoder().encode(old)
        old = try JSONDecoder().decode(Catalog.self, from: data)
        #expect(old.version == nil)

        var c = old
        let changed = c.migrate()
        #expect(changed)
        #expect(c.version == Catalog.currentVersion && c.allowlist == ["wikipedia.org"])
        #expect(c.categories.map(\.id) == ["adult", "adult-oisd", "adult-ut1", "ads", "ads-oisd", "security", "bypass",
                                           "gambling", "easylist", "blp-scam"])
        #expect(c.categories.filter(\.enabled).map(\.id) == ["adult", "ads", "security", "gambling", "easylist"])
        let gambling = try #require(c.categories.first { $0.id == "gambling" })
        #expect(gambling.custom == true && gambling.sources.first?.archiveMember == "gambling/domains")
        #expect(c.categories.first { $0.id == "ads" }?.level == .light && c.categories.first { $0.id == "security" }?.level == .light)
        #expect(c.categories.first { $0.id == "bypass" }?.sources.count == 3)
        let again = c.migrate()
        #expect(!again)

        // Ancien niveau retrouvé d'après l'adresse.
        var medium = old
        medium.categories[3].sources = [.init(url: hz + "tif.medium-onlydomains.txt")]
        medium.migrate()
        #expect(medium.categories.first { $0.id == "security" }?.level == .normal)
    }

    /// Catalogue de la 0.7.7 (version 3) : AdGuard DNS filter était une liste principale.
    /// Cochée, elle devient une liste ajoutée (toujours cochée) ; décochée, elle disparaît de la fenêtre.
    @Test func adGuardLeavesMainListsAfter077() throws {
        func v3(_ on: Bool) -> Catalog {
            var c = Catalog.default
            c.version = 3
            let i = try! #require(c.categories.firstIndex { $0.id == "ads-oisd" }) + 1
            c.categories.insert(.init(id: "adguard-dns", name: "Publicité et pistage (AdGuard)", enabled: on,
                                      sources: [], group: .ads), at: i)
            return c
        }
        var off = v3(false)
        let changed = off.migrate()
        #expect(changed && off.version == Catalog.currentVersion && off == Catalog.default)

        var on = v3(true)
        on.migrate()
        let ag = try #require(on.categories.last)
        #expect(ag.id == "adguard-dns" && ag.enabled && ag.custom == true && ag.group == nil)
        #expect(ag.sources.first?.url.hasSuffix("/AdGuardSDNSFilter/Filters/filter.txt") == true)
        #expect(Array(on.categories.dropLast()) == Catalog.default.categories)
        let again = on.migrate()
        #expect(!again)
        #expect(Catalog.otherLibrary.contains { $0.id == "adguard-dns" })
    }

    /// Catalogue de la 0.7.4 à 0.7.6 (version 2) : rien ne change, les listes ajoutées restent à la fin, dans l'ordre.
    @Test func migratesCatalogFrom074() throws {
        var c = Catalog.default
        c.version = 2
        try c.setEnabled("ads", true)
        try c.setLevel("security", .normal)
        try c.addCustomList(id: "ma-liste", name: "Ma liste", sources: [.init(url: "https://example.com/liste.txt")])
        var easylist = try #require(Catalog.otherLibrary.first { $0.id == "easylist" })
        easylist.enabled = false
        c.categories.append(easylist)
        let before = c.categories

        let changed = c.migrate()
        #expect(changed && c.version == Catalog.currentVersion && c.categories == before)
        let again = c.migrate()
        #expect(!again)
    }

    /// Nouvelle liste principale qu'un parent avait déjà ajoutée depuis le menu : elle devient principale,
    /// à sa place dans son thème, avec son état, et n'apparaît pas deux fois.
    @Test func customListBecomesMainList() throws {
        var c = Catalog.default
        c.version = 2
        let i = try #require(c.categories.firstIndex { $0.id == "ads-oisd" })
        var oisd = c.categories.remove(at: i)
        oisd.custom = true; oisd.group = nil; oisd.enabled = true
        c.categories.append(oisd)

        c.migrate()
        #expect(c.categories.map(\.id) == Catalog.default.categories.map(\.id))
        let main = try #require(c.categories.first { $0.id == "ads-oisd" })
        #expect(main.enabled && main.custom == nil && main.group == .ads)
    }

    /// Liste principale retirée par une version future, cochée : jamais perdue, même absente du menu,
    /// et jamais en double si le parent l'avait aussi ajoutée.
    @Test func retiredMainListIsNeverLost() throws {
        var c = Catalog.default
        c.version = 3
        c.categories.append(.init(id: "ancienne", name: "Ancienne liste", enabled: true,
                                  sources: [.init(url: "https://example.com/ancienne.txt")], group: .ads, level: .light))
        c.migrate()
        let kept = try #require(c.categories.last)
        #expect(kept.id == "ancienne" && kept.enabled && kept.custom == true && kept.group == nil && kept.level == nil)
        #expect(kept.name == "Ancienne liste" && kept.sources.first?.url == "https://example.com/ancienne.txt")

        // AdGuard cochée comme liste principale (0.7.7) et aussi présente, décochée, comme liste ajoutée.
        var d = Catalog.default
        d.version = 3
        d.categories.append(.init(id: "adguard-dns", name: "AdGuard", enabled: true, sources: [], group: .ads))
        var added = try #require(Catalog.otherLibrary.first { $0.id == "adguard-dns" })
        added.enabled = false
        d.categories.append(added)
        d.migrate()
        let ag = d.categories.filter { $0.id == "adguard-dns" }
        #expect(ag.count == 1 && ag.first?.enabled == true && ag.first?.custom == true)
    }

    /// Les téléchargements de KidSafe ne passent par aucun proxy (sinon le Privoxy de KidSafe peut les bloquer).
    /// Dictionnaire vide et non nil : nil voudrait dire « réglages du système ».
    @Test func ownDownloadsBypassProxy() {
        let proxies = KidSafeHTTP.session.configuration.connectionProxyDictionary
        #expect(proxies != nil && proxies?.isEmpty == true)
    }

    @Test func engineMigratesSavedCatalog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = KidSafeEngine(paths: KidSafePaths(supportDir: dir))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"categories":[{"id":"adult","name":"A","enabled":false,"sources":[]},{"id":"drugs","name":"D","enabled":true,"sources":[]}],"allowlist":[],"strictMode":false,"hardenPrivoxy":true}"#
        try Data(json.utf8).write(to: engine.paths.catalogFile)
        let c = try engine.loadCatalog()
        #expect(c.categories.first?.enabled == false && c.categories.last?.id == "drugs" && c.categories.last?.custom == true)
        #expect(try Catalog.load(from: engine.paths.catalogFile).version == Catalog.currentVersion)
    }

    @Test func restoreDefaultsTabByTab() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = KidSafeEngine(paths: KidSafePaths(supportDir: dir))
        var c = Catalog.default
        try c.setEnabled("adult", false)
        try c.setEnabled("ads", true)
        try c.setLevel("security", .strong)
        let gambling = try #require(Catalog.library.first { $0.id == "gambling" })
        try c.addCustomList(id: gambling.id, name: gambling.name, sources: gambling.sources, warning: gambling.warning)
        c.services["tiktok"] = ServicePolicy(mode: .blocked)
        c.blockedDomains = ["roblox.com"]; c.allowlist = ["wikipedia.org"]
        c.strictMode = true; c.notifyBlocked = false; c.refreshHours = 0; c.blockWhenClosed = true
        let edited = c

        try engine.resetLists(&c)
        #expect(c.categories == Catalog.default.categories)
        #expect(c.blockedDomains == ["roblox.com"] && c.services == edited.services)   // les autres onglets ne bougent pas
        c.resetSocial()
        #expect(c.services.isEmpty && c.allowlist == ["wikipedia.org"])
        c.resetDomains()
        #expect(c.blockedDomains.isEmpty && c.allowlist.isEmpty && c.strictMode)
        c.resetGeneral()
        #expect(!c.strictMode && c.notifyBlocked && c.refreshHours == 24)
        #expect(c.blockWhenClosed)   // les protections contre les contournements restent
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
        #expect(Catalog.default.categories.first { $0.id == "adult-ut1" }?.displayWarning?.hasPrefix("Very large list") == true)
        #expect(Catalog.library.first?.name == "Gambling (UT1)")
        #expect(Catalog.default.categories[0].listName == "HaGeZi NSFW")
        #expect(ListGroup.security.title == "Scams, phishing, malware" && ListLevel.strong.title == "Strong")
    }

    /// Chaque liste proposée a sa fiche ⓘ, traduite dans les deux langues.
    @Test func everyKnownListHasAnInfoSheet() {
        defer { Localization.forcedLanguage = "fr" }
        for lang in ["fr", "en"] {
            Localization.forcedLanguage = lang
            for c in Catalog.default.categories + Catalog.library {
                let info = c.info
                #expect(info != nil, "fiche manquante : \(c.id)")
                guard let info else { continue }
                #expect(info.description != info.descriptionKey, "description manquante (\(lang)) : \(c.id)")
                #expect(!info.updates.text.hasPrefix("info.") && !info.risk.text.hasPrefix("info."))
                #expect(L("library." + c.id) != "library." + c.id || c.custom != true)
                if let g = c.group { #expect(g.title != "group." + g.rawValue && c.listName != c.displayName) }
            }
            #expect(ListInfo.Updates.stale("month.2026-07").text.contains("2026"))
            #expect(Catalog.info(for: "ma-liste") == nil)
        }
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
        #expect(try cfg().contains("\ntoggle 0\n"))   // Privoxy entièrement désactivé
        #expect(FileManager.default.fileExists(atPath: conf.appendingPathComponent("kidsafe-cat-a.action").path))
        #expect(try !engine.refreshServices(c, installer: inst))

        c.filteringEnabled = true
        _ = try await engine.apply(c, installer: inst)
        #expect(!inst.isPaused())
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try cfg()).first == "kidsafe-cat-a.action")
        #expect(try cfg().contains("\ntoggle 1\n") && !(try cfg()).contains("\ntoggle 0\n"))
    }
}

@Suite struct BundledPrivoxyTests {
    @Test func adaptsTemplate() {
        let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/KidSafe/privoxy")
        let out = BundledPrivoxy.adapt("confdir .\nlogdir .\n#listen-address [::1]:8118\nlisten-address  127.0.0.1:8118\ntoggle 1\nelliptic-curve-keys 1", dir: dir)
        #expect(out.hasPrefix("confdir \(dir.path)\nlogdir \(dir.path)/log\n#listen-address [::1]:8118\nlisten-address  127.0.0.1:\(BundledPrivoxy.port)\ntoggle 1\n#elliptic-curve-keys 1"))
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

@Suite struct UpdateCheckerTests {
    @Test(arguments: [("0.3.2", "0.3.1", true), ("0.10.0", "0.9.9", true), ("1.0", "0.9.9", true),
                      ("0.3.1", "0.3.1", false), ("0.3.0", "0.3.1", false), ("0.3.1", "0.3", true), ("0.3", "0.3.0", false)])
    func compare(_ a: String, _ b: String, _ newer: Bool) {
        #expect(UpdateChecker.isNewer(a, than: b) == newer)
    }

    @Test func parseGitHubRelease() throws {
        let json = #"{"tag_name":"v0.3.2","html_url":"https://github.com/lls-hcr/kidsafe/releases/tag/v0.3.2","draft":false,"prerelease":false,"assets":[{"name":"privoxy-4.2.0.tar.gz","browser_download_url":"https://x/p.tar.gz"},{"name":"KidSafe.dmg","browser_download_url":"https://x/KidSafe.dmg"}]}"#
        let r = try UpdateChecker.parse(Data(json.utf8))
        #expect(r.version == "0.3.2")
        #expect(r.downloadURL?.absoluteString == "https://x/KidSafe.dmg")
        #expect(r.dmgSHA256 == nil)   // ni « digest » ni empreinte dans les notes
        #expect(throws: UpdateChecker.CheckError.self) { try UpdateChecker.parse(Data("{}".utf8)) }
    }
}

@Suite struct AutoUpdateTests {
    @Test func checksumFromGitHubDigestOrReleaseNotes() throws {
        let h = String(repeating: "ab", count: 32)
        let withDigest = #"{"tag_name":"v0.4.0","html_url":"https://g/r","assets":[{"name":"KidSafe.dmg","browser_download_url":"https://g/KidSafe.dmg","digest":"sha256:"# + h + #""}]}"#
        #expect(try UpdateChecker.parse(Data(withDigest.utf8)).dmgSHA256 == h)
        let inNotes = #"{"tag_name":"v0.4.0","html_url":"https://g/r","body":"Notes\nSHA-256 `KidSafe.dmg`: `"# + h.uppercased() + #"`","assets":[{"name":"KidSafe.dmg","browser_download_url":"https://g/KidSafe.dmg"}]}"#
        #expect(try UpdateChecker.parse(Data(inNotes.utf8)).dmgSHA256 == h)
    }

    @Test func refusesWithoutChecksumOrWithWrongOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("KidSafe.dmg")
        try "pas un vrai dmg".write(to: fake, atomically: true, encoding: .utf8)
        let page = URL(string: "https://g/r")!
        await #expect(throws: AppUpdater.UpdateError.self) {
            try await AppUpdater.prepare(.init(version: "9.9", pageURL: page, downloadURL: fake), currentVersion: "0.1",
                                         bundleID: "app.kidsafe.KidSafe", stagingDir: dir.appendingPathComponent("s1"))
        }
        await #expect(throws: AppUpdater.UpdateError.self) {
            try await AppUpdater.prepare(.init(version: "9.9", pageURL: page, downloadURL: fake, dmgSHA256: String(repeating: "0", count: 64)),
                                         currentVersion: "0.1", bundleID: "app.kidsafe.KidSafe", stagingDir: dir.appendingPathComponent("s2"))
        }
        #expect(!AppUpdater.canReplace(URL(fileURLWithPath: "/Volumes/KidSafe/KidSafe.app")))
    }

    @Test func teamIDOfSignedAndUnsignedCode() throws {
        // Signature ad hoc ou absente : pas de Team ID, donc aucune exigence pour la mise à jour.
        let tool = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-adhoc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tool) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: tool)
        try AppUpdater.run("/usr/bin/codesign", ["--force", "--sign", "-", tool.path])
        #expect(AppUpdater.teamID(of: tool) == nil)
        #expect(AppUpdater.teamID(of: FileManager.default.temporaryDirectory) == nil)
    }

    // MARK: KidSafe devient Yamoxy

    @Test func checksumInNotesForRenamedDmg() throws {
        let h = String(repeating: "cd", count: 32)
        let json = #"{"tag_name":"v0.9.0","html_url":"https://g/r","body":"SHA-256 `Yamoxy.dmg` : `"# + h + #"`","assets":[{"name":"Yamoxy.dmg","browser_download_url":"https://g/Yamoxy.dmg"}]}"#
        let r = try UpdateChecker.parse(Data(json.utf8))
        #expect(r.dmgSHA256 == h && r.downloadURL?.lastPathComponent == "Yamoxy.dmg")
    }

    /// Fausse app signée ad hoc (un exécutable, un Info.plist) ; `marker` permet de la reconnaître après une copie.
    private func fakeApp(_ url: URL, bundleID: String = "app.kidsafe.KidSafe", version: String = "9.9", marker: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                                  "CFBundleExecutable": "app", "CFBundlePackageType": "APPL"]
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/app"))
        try marker.write(to: url.appendingPathComponent("Contents/Resources/marker.txt"), atomically: true, encoding: .utf8)
        try AppUpdater.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }

    private func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8) }

    /// Un .dmg qui contient `Yamoxy.app` (même identifiant) est accepté et préparé sous ce nom ;
    /// une app d'un autre identifiant est refusée.
    @Test func acceptsRenamedAppInDmg() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("kidsafe-yamoxy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        func dmg(_ name: String, bundleID: String) throws -> (URL, String) {
            let src = dir.appendingPathComponent("src-\(name)-\(bundleID)")
            try fakeApp(src.appendingPathComponent(name), bundleID: bundleID, marker: "nouvelle")
            let out = dir.appendingPathComponent("\(UUID().uuidString).dmg")
            try AppUpdater.run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-srcfolder", src.path, "-format", "UDZO", out.path])
            let sha = SHA256Hex(try Data(contentsOf: out))
            return (out, sha)
        }
        let page = URL(string: "https://g/r")!

        let (good, sha) = try dmg("Yamoxy.app", bundleID: "app.kidsafe.KidSafe")
        let staged = try await AppUpdater.prepare(.init(version: "9.9", pageURL: page, downloadURL: good, dmgSHA256: sha),
                                                  currentVersion: "0.8.0", bundleID: "app.kidsafe.KidSafe",
                                                  stagingDir: dir.appendingPathComponent("s1"))
        #expect(staged.lastPathComponent == "Yamoxy.app" && marker(staged) == "nouvelle")

        let (other, sha2) = try dmg("Yamoxy.app", bundleID: "com.example.autre")
        await #expect(throws: AppUpdater.UpdateError.self) {
            try await AppUpdater.prepare(.init(version: "9.9", pageURL: page, downloadURL: other, dmgSHA256: sha2),
                                         currentVersion: "0.8.0", bundleID: "app.kidsafe.KidSafe",
                                         stagingDir: dir.appendingPathComponent("s2"))
        }
    }

    private func SHA256Hex(_ data: Data) -> String {
        // Même calcul que l'app (CryptoKit), via shasum pour ne pas dépendre d'un import de plus.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-sha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try? data.write(to: file)
        let out = (try? AppUpdater.run("/usr/bin/shasum", ["-a", "256", file.path])) ?? ""
        return String(out.prefix(64))
    }

    /// Le vrai script de remplacement, sans relance, dans un dossier temporaire.
    /// Renvoie le dossier « Applications » une fois le script terminé (il supprime le dossier de préparation en dernier).
    private func runReplace(current: String, staged: String?, existing: [String: String] = [:]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kidsafe-replace-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Applications"), staging = root.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try fakeApp(apps.appendingPathComponent(current), version: "0.8.0", marker: "ancienne")
        for (name, mark) in existing { try fakeApp(apps.appendingPathComponent(name), marker: mark) }
        let stagedURL = staging.appendingPathComponent(staged ?? "Yamoxy.app")
        if staged != nil { try fakeApp(stagedURL, marker: "nouvelle") }   // nil : copie impossible (échec simulé)
        try AppUpdater.scheduleReplace(current: apps.appendingPathComponent(current), staged: stagedURL, stagingDir: staging,
                                       pid: Int32.max, relaunch: false)
        let end = Date().addingTimeInterval(20)
        while fm.fileExists(atPath: staging.path) && Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        #expect(!fm.fileExists(atPath: staging.path))
        return apps
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func replaceInstallsUnderNewName() throws {
        let apps = try runReplace(current: "KidSafe.app", staged: "Yamoxy.app")
        defer { try? FileManager.default.removeItem(at: apps.deletingLastPathComponent()) }
        #expect(names(apps) == ["Yamoxy.app"])
        #expect(marker(apps.appendingPathComponent("Yamoxy.app")) == "nouvelle")
    }

    @Test func replaceKeepsSameNameAsBefore() throws {
        let apps = try runReplace(current: "KidSafe.app", staged: "KidSafe.app")
        defer { try? FileManager.default.removeItem(at: apps.deletingLastPathComponent()) }
        #expect(names(apps) == ["KidSafe.app"])
        #expect(marker(apps.appendingPathComponent("KidSafe.app")) == "nouvelle")
    }

    /// Une app porte déjà le nouveau nom : on n'y touche pas, la mise à jour se fait sous l'ancien nom.
    @Test func replaceNeverOverwritesAnotherApp() throws {
        let apps = try runReplace(current: "KidSafe.app", staged: "Yamoxy.app", existing: ["Yamoxy.app": "autre"])
        defer { try? FileManager.default.removeItem(at: apps.deletingLastPathComponent()) }
        #expect(names(apps) == ["KidSafe.app", "Yamoxy.app"])
        #expect(marker(apps.appendingPathComponent("KidSafe.app")) == "nouvelle")
        #expect(marker(apps.appendingPathComponent("Yamoxy.app")) == "autre")
    }

    /// Copie impossible : l'ancienne app est remise en place, à son nom, intacte.
    @Test func replaceRestoresOldAppOnFailure() throws {
        let apps = try runReplace(current: "KidSafe.app", staged: nil)
        defer { try? FileManager.default.removeItem(at: apps.deletingLastPathComponent()) }
        #expect(names(apps) == ["KidSafe.app"])
        #expect(marker(apps.appendingPathComponent("KidSafe.app")) == "ancienne")
    }
}

@Suite struct AdvancedTests {
    @Test func editorAndLogOptionsInConfig() {
        let base = ConfigEditorTests.config
        let off = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: base)
        #expect(off.contains("enable-edit-actions 0") && !off.contains("debug 1024"))
        let on = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: base, options: .init(editActions: true, logBlocked: true))
        #expect(on.contains("enable-edit-actions 1") && on.contains("debug 1024"))
        #expect(on.contains("enforce-blocks 1") && on.contains("enable-remote-toggle 0"))   // protections maintenues
        #expect(PrivoxyConfigEditor.remove(from: on) == base)
    }

    @Test func temporaryPause() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var c = Catalog.default
        #expect(!c.pauseExpired(at: now))
        c.filteringEnabled = false
        #expect(!c.pauseExpired(at: now))                      // pause sans limite : jamais de reprise automatique
        c.pausedUntil = now.addingTimeInterval(30)
        #expect(!c.pauseExpired(at: now.addingTimeInterval(29)))
        #expect(c.pauseExpired(at: now.addingTimeInterval(30)))
        c.filteringEnabled = true
        #expect(!c.pauseExpired(at: now.addingTimeInterval(60)))  // déjà repris
        #expect(Catalog.pauseChoices.allSatisfy { L("app.pause.\(Int($0))") != "app.pause.\(Int($0))" })

        // Enregistrée avec le catalogue ; absente des anciens fichiers.
        c.filteringEnabled = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-pause-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try c.save(to: url)
        #expect(try Catalog.load(from: url).pausedUntil == c.pausedUntil)
        let old = try JSONDecoder().decode(Catalog.self, from: Data(#"{"categories": []}"#.utf8))
        #expect(old.pausedUntil == nil && old.filteringEnabled)
    }

    @Test func pauseDisablesPrivoxyEntirely() {
        let base = ConfigEditorTests.config
        for harden in [true, false] {
            let paused = PrivoxyConfigEditor.apply(actionFiles: [], to: base, options: .init(harden: harden, active: false))
            let active = paused.split(separator: "\n").filter { PrivoxyConfigEditor.directiveName(String($0)) == "toggle" }
            #expect(active == ["toggle 0"])
            #expect(PrivoxyConfigEditor.remove(from: paused) == base)
        }
        let unhardened = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: base, options: .init(harden: false))
        #expect(unhardened.contains("\ntoggle  1\n") && !unhardened.contains("toggle 0"))
    }

    @Test func relayKeepsListsButFiltersNothing() {
        let base = ConfigEditorTests.config
        for harden in [true, false] {
            let relay = PrivoxyConfigEditor.apply(actionFiles: ["a.action"], to: base, options: .init(harden: harden, relay: true))
            let toggles = relay.split(separator: "\n").filter { PrivoxyConfigEditor.directiveName(String($0)) == "toggle" }
            #expect(toggles == ["toggle 0"])
            // Pas une pause : les listes restent déclarées, et KidSafe les réactive sans rien réinstaller.
            #expect(!PrivoxyConfigEditor.isPaused(relay))
            #expect(PrivoxyConfigEditor.managedActionFiles(in: relay) == ["a.action"])
            #expect(PrivoxyConfigEditor.remove(from: relay) == base)
        }
    }

    @Test func editorClosesAfterDelay() {
        let now = Date()
        #expect(AdvancedSettings(editorUntil: now.addingTimeInterval(60)).editorActive(at: now))
        #expect(!AdvancedSettings(editorUntil: now.addingTimeInterval(-1)).editorActive(at: now))
        #expect(!AdvancedSettings().editorActive(at: now))
    }

    @Test func bypassEntries() {
        #expect(AdvancedSettings.normalizeBypass("*.Exemple.org") == "*.exemple.org")
        #expect(AdvancedSettings.normalizeBypass("https://intranet.corp.example/x") == "intranet.corp.example")
        #expect(AdvancedSettings.normalizeBypass("192.168.1.10") == "192.168.1.10")
        #expect(AdvancedSettings.normalizeBypass("pas valide") == nil)
        let a = AdvancedSettings(proxyBypass: ["localhost", "corp.example"])
        #expect(a.bypassDomains == ["localhost", "127.0.0.1", "*.local", "corp.example"])
    }

    @Test func olderCatalogsGetDefaultAdvancedSettings() throws {
        let json = #"{"categories":[]}"#
        let c = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        #expect(c.advanced == AdvancedSettings())
    }

    @Test func blockLogLines() {
        let e = BlockLog.parse("2026-11-21 02:30:12.345 0000700001 Crunch: Blocked: www.tiktok.com:443")
        #expect(e?.host == "www.tiktok.com" && e?.target == "www.tiktok.com:443")
        #expect(BlockLog.parse("2026-11-21 02:30:12.345 0000700001 Crunch: Blocked: http://bad.example/page")?.host == "bad.example")
        #expect(BlockLog.parse("2026-11-21 02:30:12.345 0000700001 Request: example.com/") == nil)
    }

    @Test func changePortInConfig() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-port-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: f) }
        try "confdir /x\nlisten-address  127.0.0.1:8128\n#listen-address [::1]:8118\n".write(to: f, atomically: true, encoding: .utf8)
        try BundledPrivoxy.setPort(8130, configFile: f)
        #expect(SystemStatus.listenAddress(configFile: f).port == 8130)
        #expect(try String(contentsOf: f, encoding: .utf8).contains("#listen-address [::1]:8118"))
    }
}

/// Test d'intégration avec le vrai Privoxy compilé (build/privoxy) : ignoré s'il n'est pas construit.
@Suite(.serialized) struct RealPrivoxyAdvancedTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let privoxy = root.appendingPathComponent("build/privoxy")

    func curl(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--max-time", "5"] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }

    /// KidSafe fermé : Privoxy reste allumé en simple relais (rien n'est bloqué), puis filtre de nouveau au relancement.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: privoxy.appendingPathComponent("privoxy").path)))
    func relayAfterQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-relay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("KidSafe.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("privoxy"), to: app.appendingPathComponent("Helpers/privoxy"))
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("conf"), to: app.appendingPathComponent("Resources/privoxy-conf"))
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("VERSION"), to: app.appendingPathComponent("Resources/privoxy-conf/VERSION"))
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleVersion</key><string>1</string></dict></plist>"
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: root.appendingPathComponent("KidSafe.app")))
        let inst = try #require(try BundledPrivoxy.prepare(bundle: bundle, supportDir: root.appendingPathComponent("support"), port: 8143))
        _ = try inst.install(.init(files: [("kidsafe-cat-t.action", "{ +block{test} }\n.bad.example\n")], options: .init()))
        let ctl = PrivoxyController(binary: inst.privoxyBinary, configFile: inst.configFile, host: "127.0.0.1", port: 8143, useLaunchAgent: false)
        #expect(ctl.start())
        defer { ctl.stop() }
        let status = { self.curl(["-x", "http://127.0.0.1:8143", "-o", "/dev/null", "-w", "%{http_code}", "http://bad.example/"]) }
        #expect(status() == "403")   // bloqué

        // Fermeture de KidSafe : relais. Privoxy répond toujours, mais ne bloque plus rien.
        try inst.updateOptions(.init(relay: true))
        try await Task.sleep(for: .seconds(1))
        #expect(ctl.isListening)
        #expect(status() != "403")
        #expect(!inst.isPaused())

        // Relancement : options normales, le filtrage reprend sans réinstaller les listes.
        try inst.updateOptions(.init())
        try await Task.sleep(for: .seconds(1))
        #expect(status() == "403")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: privoxy.appendingPathComponent("privoxy").path)))
    func editorLogPortAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-adv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // Faux KidSafe.app contenant le vrai Privoxy compilé.
        let app = root.appendingPathComponent("KidSafe.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("privoxy"), to: app.appendingPathComponent("Helpers/privoxy"))
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("conf"), to: app.appendingPathComponent("Resources/privoxy-conf"))
        try FileManager.default.copyItem(at: Self.privoxy.appendingPathComponent("VERSION"), to: app.appendingPathComponent("Resources/privoxy-conf/VERSION"))
        try "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleVersion</key><string>1</string></dict></plist>"
            .write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(url: root.appendingPathComponent("KidSafe.app")))
        let support = root.appendingPathComponent("support")

        // Installation sur le port 8141, une liste bloquant bad.example.
        let inst = try #require(try BundledPrivoxy.prepare(bundle: bundle, supportDir: support, port: 8141))
        _ = try inst.install(.init(files: [("kidsafe-cat-t.action", "{ +block{test} }\n.bad.example\n")], options: .init()))
        var ctl = PrivoxyController(binary: inst.privoxyBinary, configFile: inst.configFile, host: "127.0.0.1", port: 8141, useLaunchAgent: false)
        #expect(ctl.start())
        defer { ctl.stop() }
        let proxy = ["-x", "http://127.0.0.1:8141"]

        // Éditeur fermé par défaut, ouvert par l'option (Privoxy relit la config tout seul).
        #expect(curl(proxy + ["http://p.p/edit-actions-list?f=0"]).contains("disabled"))
        try inst.updateOptions(.init(editActions: true, logBlocked: true))
        try await Task.sleep(for: .seconds(1))
        #expect(!curl(proxy + ["http://p.p/edit-actions-list?f=0"]).contains("is disabled"))

        // Journal : un site bloqué apparaît.
        _ = curl(proxy + ["http://bad.example/"])
        var logged = false
        for _ in 0..<15 where !logged {
            try await Task.sleep(for: .milliseconds(200))
            logged = BlockLog.recent(BlockLog.logFile(confDir: inst.confDir)).contains { $0.host == "bad.example" }
        }
        #expect(logged, "journal : \((try? String(contentsOf: BlockLog.logFile(confDir: inst.confDir), encoding: .utf8)) ?? "absent")")

        // Compteurs du moniteur, lus directement sur le port de Privoxy.
        let counters = await Monitor.counters(host: "127.0.0.1", port: 8141)
        #expect(counters != nil && (counters?.requests ?? 0) >= 2 && (counters?.blocked ?? 0) >= 1)
        #expect(counters?.since != nil)

        // Changement de port.
        ctl.stop()
        try BundledPrivoxy.setPort(8142, configFile: inst.configFile)
        ctl = PrivoxyController(binary: inst.privoxyBinary, configFile: inst.configFile, host: "127.0.0.1", port: 8142, useLaunchAgent: false)
        #expect(ctl.start())
        #expect(curl(["-x", "http://127.0.0.1:8142", "http://p.p/"]).contains("8142"))

        // Réinitialisation : user.action d'origine, listes KidSafe conservées.
        try "{ +block } \n.perso.example\n".write(to: inst.confDir.appendingPathComponent("user.action"), atomically: true, encoding: .utf8)
        let reset = try #require(try BundledPrivoxy.reset(bundle: bundle, supportDir: support, port: 8142))
        #expect(!(try String(contentsOf: reset.confDir.appendingPathComponent("user.action"), encoding: .utf8)).contains("perso.example"))
        #expect(PrivoxyConfigEditor.managedActionFiles(in: try String(contentsOf: reset.configFile, encoding: .utf8)).contains("kidsafe-cat-t.action"))
        try reset.testConfig()
    }
}

@Suite(.serialized) struct MonitorTests {
    init() { Localization.forcedLanguage = "fr" }

    @Test func parsesPrivoxyCounters() {
        let html = "<p>   519 out of 3587 requests have been blocked,\n which equals a block rate of 14.47%.</p>"
        let c = Monitor.parseCounters(html)
        #expect(c?.blocked == 519 && c?.requests == 3587)
        #expect(Monitor.parseCounters("<p>nothing</p>") == nil)
    }

    @Test func summarizesLogAndCategories() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-mon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# x\n{ +block{KidSafe : Contenus pour adultes} }\n.bad.example\n{ -block }\n.ok.bad.example\n"
            .write(to: dir.appendingPathComponent("kidsafe-cat-adult.action"), atomically: true, encoding: .utf8)
        try "{ +block{KidSafe : TikTok} }\n.tiktok.com\n".write(to: dir.appendingPathComponent("kidsafe-services.action"), atomically: true, encoding: .utf8)
        let index = Monitor.CategoryIndex(confDir: dir)
        #expect(index.category(of: "www.bad.example") == "Contenus pour adultes")
        #expect(index.category(of: "ok.bad.example") == nil)       // exception : pas une catégorie de blocage
        #expect(index.category(of: "m.tiktok.com") == "TikTok")

        let now = Date()
        func e(_ host: String, _ ago: TimeInterval) -> BlockLog.Entry { .init(date: now.addingTimeInterval(-ago), target: host, host: host) }
        let s = Monitor.summarize([e("www.bad.example", 60), e("www.bad.example", 120), e("tiktok.com", 7200), e("old.example", 9 * 86400)],
                                  index: index, now: now)
        #expect(s.total == 4)
        // Les deux blocages d'il y a 1 et 2 min : heure en cours, ou la précédente juste après l'heure pile.
        #expect(s.perHour.count == 24 && s.perHour.suffix(2).map(\.count).reduce(0, +) >= 2)
        #expect(s.perDay.count == 7 && s.perDay.map(\.count).reduce(0, +) == 3)   // la ligne d'il y a 9 jours est hors période
        #expect(s.topDomains.first?.host == "www.bad.example" && s.topDomains.first?.count == 2)
        #expect(s.perCategory.first?.name == "Contenus pour adultes")

        let html = Dashboard.html(.init(counters: .init(requests: 1000, blocked: 120, since: now), domainsOnLists: 87887,
                                        summary: s, logEnabled: true, version: "0.6.0"))
        #expect(html.contains("Requêtes bloquées") && html.contains("12,0 %") && html.contains("www.bad.example"))
        #expect(!html.contains("http://") && !html.contains("https://"))   // page autonome, aucun appel externe
        #expect(html.contains("kidsafe://dashboard/refresh") && html.contains("Instantané du"))
        #expect(html.contains("Blocages enregistrés (7 jours)"))
        #expect(Dashboard.esc("<b>&\"") == "&lt;b&gt;&amp;&quot;")
    }
}

@Suite(.serialized) struct GuideTests {
    @Test func guideInBothLanguages() throws {
        defer { Localization.forcedLanguage = "fr" }
        Localization.forcedLanguage = "fr"
        let fr = try #require(UserGuide.html(version: "1.0"))
        #expect(fr.contains("Guide d'utilisation") && fr.contains("id=\"desinstaller\"") && fr.contains("lang=\"fr\""))
        Localization.forcedLanguage = "en"
        let en = try #require(UserGuide.html(version: "1.0"))
        #expect(en.contains("User guide") && en.contains("id=\"uninstall\"") && en.contains("lang=\"en\""))
        // Captures intégrées (une par {{shot:…}}), aucun espace réservé restant.
        for page in [fr, en] {
            #expect(page.matches(of: /data:image\/(png|jpeg);base64,/).count == 12)
            #expect(!page.contains("{{shot:"))
        }
        // Chaque lien du sommaire pointe vers une section existante.
        for page in [fr, en] {
            let anchors = page.matches(of: /href="#([a-z\-]+)"/).map { String($0.1) }
            #expect(!anchors.isEmpty)
            for a in anchors { #expect(page.contains("id=\"\(a)\""), "ancre manquante : \(a)") }
        }
    }
}

@Suite struct BlockNotifierTests {
    @Test func reportsOnlyVisibleBlocksOncePerSite() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-notify-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("log"), withIntermediateDirectories: true)
        func write(_ name: String, _ text: String) throws { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try write("kidsafe-cat-adult.action", "# KidSafe\n\n{ +block{KidSafe : Adultes} }\n.pornhub.com\n.xvideos.com\n\n{ -block }\n.safe.xvideos.com\n")
        try write("kidsafe-cat-ads.action", "# KidSafe\n\n{ +block{KidSafe : Publicité} }\n.doubleclick.net\n")
        try write(PrivoxyActions.customBlockFileName, PrivoxyActions.customBlockFile(domains: ["roblox.com"]))
        let tiktok = try #require(SocialService.all.first { $0.id == "tiktok" })
        try write(PrivoxyActions.servicesFileName, PrivoxyActions.servicesFile(blocked: [tiktok]))
        let log = BlockLog.logFile(confDir: dir)
        try "2026-11-21 08:00:00.000 01 Crunch: Blocked: www.pornhub.com:443\n".write(to: log, atomically: true, encoding: .utf8)

        let n = BlockNotifier(confDir: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(n.poll(now: t0) == nil)                       // lignes déjà présentes : ignorées
        func append(_ hosts: [String], partial: String = "") throws {
            let h = try FileHandle(forWritingTo: log); defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: Data((hosts.map { "2026-11-21 08:00:01.000 02 Crunch: Blocked: \($0)\n" }.joined() + partial).utf8))
        }

        try append(["ad.doubleclick.net:443", "unknown.example:443", "safe.xvideos.com:443"])
        #expect(n.poll(now: t0) == nil)                       // publicité, règle de base de Privoxy, exception
        try append(["www.pornhub.com:443", "pornhub.com:443"])
        #expect(n.poll(now: t0) == .init(site: "pornhub.com", reason: "Adultes", key: "pornhub.com"))
        #expect(n.poll(now: t0) == nil)                       // même site : déjà signalé
        try append([], partial: "2026-11-21 08:00:02.000 03 Crunch: Blocked: rob")
        #expect(n.poll(now: t0) == nil)                       // ligne incomplète : attend la suite
        try append([], partial: "lox.com:443\n")
        #expect(n.poll(now: t0)?.reason == L("action.reason.custom"))
        let first = try #require(tiktok.domains.first), second = try #require(tiktok.domains.dropFirst().first)
        try append([first + ":443"])
        #expect(n.poll(now: t0)?.key == "service:" + tiktok.name)
        try append([second + ":443"])
        #expect(n.poll(now: t0) == nil)                       // TikTok : une seule notification pour tous ses domaines
        try append(["http://www.pornhub.com/video"])
        #expect(n.poll(now: t0.addingTimeInterval(BlockNotifier.repeatInterval + 1))?.site == "pornhub.com")

        BlockLog.clear(log)                                   // journal vidé : reprise au début
        #expect(n.poll(now: t0) == nil)
        try append(["xvideos.com:443"])
        #expect(n.poll(now: t0)?.site == "xvideos.com")
    }
}

@Suite struct ProtectionTests {
    @Test func blockWhenClosedNeedsPasswordAndDecodesOldFiles() throws {
        var c = Catalog.default
        #expect(!c.blockWhenClosed && !c.keepsProxyWhenClosed)
        c.blockWhenClosed = true
        #expect(!c.keepsProxyWhenClosed)   // sans mot de passe, n'importe qui peut quitter KidSafe
        c.parentPassword = PasswordHash.make("secret")
        #expect(c.keepsProxyWhenClosed)
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Catalog.self, from: data).keepsProxyWhenClosed)
        // Fichier d'une version précédente : réglage absent → désactivé.
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["blockWhenClosed"] = nil
        let old = try JSONDecoder().decode(Catalog.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.blockWhenClosed)
    }

    @Test func firefoxRuleKeepsOtherPolicies() {
        let other: [String: Any] = ["EnterprisePoliciesEnabled": true, "DisableTelemetry": true]
        let merged = FirefoxPolicy.merged(other)
        #expect(FirefoxPolicy.isInstalled(merged))
        #expect(merged["DisableTelemetry"] as? Bool == true)
        let removed = FirefoxPolicy.removed(merged)
        #expect(!FirefoxPolicy.isInstalled(removed))
        #expect(removed["DisableTelemetry"] as? Bool == true && removed["EnterprisePoliciesEnabled"] as? Bool == true)
        // Seule la règle de KidSafe : tout est retiré, y compris l'activation des règles.
        #expect(FirefoxPolicy.removed(FirefoxPolicy.merged([:])).isEmpty)
        // Règle présente mais non verrouillée, ou règles désactivées : pas verrouillé.
        #expect(!FirefoxPolicy.isInstalled(["EnterprisePoliciesEnabled": true, "Proxy": ["Mode": "system"]]))
        #expect(!FirefoxPolicy.isInstalled(["Proxy": ["Mode": "system", "Locked": true]]))
        // Liste de propriétés valide pour `defaults import`.
        #expect((try? PropertyListSerialization.data(fromPropertyList: merged, format: .xml, options: 0)) != nil)
    }

    @Test func heartbeatAndEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-events-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let beat = Heartbeat.file(supportDir: dir), events = EventLog.file(supportDir: dir)
        #expect(Heartbeat.lastBeat(beat) == nil)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        Heartbeat.beat(beat, now: t)
        Heartbeat.beat(beat, now: t.addingTimeInterval(30))
        #expect(Heartbeat.lastBeat(beat).map { abs($0.timeIntervalSince(t.addingTimeInterval(30))) < 1 } == true)
        Heartbeat.clear(beat)
        #expect(Heartbeat.lastBeat(beat) == nil)   // arrêt normal : rien à signaler au lancement suivant

        for i in 0..<(EventLog.keep + 5) {
            EventLog.append(.init(date: t.addingTimeInterval(Double(i) * 60), kind: .unexpectedStop, lastSeen: t), to: events)
        }
        EventLog.append(.init(date: t.addingTimeInterval(-30 * 24 * 3600), kind: .loginItemDisabled), to: events)
        let all = EventLog.load(events)
        #expect(all.count == EventLog.keep)
        // Récents : moins d'une semaine, du plus récent au plus ancien.
        let recent = EventLog.recent(events, now: t.addingTimeInterval(3600 * 2))
        #expect(recent.first?.kind == .unexpectedStop && recent.count == EventLog.keep - 1)
        #expect(recent.first!.date > recent.last!.date)
        Localization.forcedLanguage = "fr"
        defer { Localization.forcedLanguage = nil }
        #expect(EventLog.describe(recent[0], locale: Locale(identifier: "fr")).contains("inattendue"))
    }
}

@Suite struct ListStatusTests {
    @Test func fetcherKnowsWhenAListChanged() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-fetch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("list.txt")
        let src = Catalog.Source(url: file.absoluteString)
        let fetcher = SourceFetcher(cacheDir: dir.appendingPathComponent("cache"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        try "a.example\nb.example\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try await fetcher.fetch(src, now: t0)
        #expect(!first.unchanged && !first.fromCache && first.changed == t0)

        // Même contenu : inchangée, la date de changement reste celle du premier téléchargement.
        let same = try await fetcher.fetch(src, now: t0.addingTimeInterval(3600))
        #expect(same.unchanged && same.changed == t0 && same.dataDate == t0.addingTimeInterval(3600))

        try "a.example\nc.example\n".write(to: file, atomically: true, encoding: .utf8)
        let t2 = t0.addingTimeInterval(7200)
        let changed = try await fetcher.fetch(src, now: t2)
        #expect(!changed.unchanged && changed.changed == t2)

        // Source disparue : copie du cache, datée de la dernière vérification réussie.
        try FileManager.default.removeItem(at: file)
        let cached = try await fetcher.fetch(src, now: t0.addingTimeInterval(9000))
        #expect(cached.fromCache && cached.dataDate == t2 && cached.warning != nil)
        #expect(String(decoding: cached.data, as: UTF8.self).contains("c.example"))
    }

    @Test func engineReportsStepsAndStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-lists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let conf = root.appendingPathComponent("conf")
        try FileManager.default.createDirectory(at: conf, withIntermediateDirectories: true)
        try "listen-address 127.0.0.1:8118\nactionsfile user.action\n".write(to: conf.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let list = root.appendingPathComponent("adult.txt")
        try "a.example\nb.example\n".write(to: list, atomically: true, encoding: .utf8)
        var catalog = Catalog(categories: [.init(id: "t", name: "Test", enabled: true, sources: [.init(url: list.absoluteString)])])
        catalog.hardenPrivoxy = false
        let engine = KidSafeEngine(paths: KidSafePaths(supportDir: root.appendingPathComponent("support")))
        let installer = PrivoxyInstaller(confDir: conf, privoxyBinary: nil)

        final class Steps: @unchecked Sendable { var all: [ListProgress] = []; let lock = NSLock() }
        let steps = Steps()
        let r1 = try await engine.apply(catalog, installer: installer) { _, s in steps.lock.lock(); steps.all.append(s); steps.lock.unlock() }
        #expect(steps.all.contains(.converting) && steps.all.last == .installing)
        #expect(steps.all.contains { if case .downloading = $0 { true } else { false } })
        #expect(r1.status.lists["t"]?.changedNow == true && r1.status.lists["t"]?.delta == nil)   // première fois

        let r2 = try await engine.apply(catalog, installer: installer)
        #expect(r2.status.lists["t"]?.changedNow == false && r2.status.lists["t"]?.delta == 0)
        #expect(r2.status.summary(for: ["t"]) == .init(checked: 1, updated: 0, unchanged: 1, failed: 0))

        try "a.example\nb.example\nc.example\n".write(to: list, atomically: true, encoding: .utf8)
        let r3 = try await engine.apply(catalog, installer: installer)
        #expect(r3.status.lists["t"]?.changedNow == true && r3.status.lists["t"]?.delta == 1)

        // Téléchargement impossible : copie utilisée, comptée comme échec dans le résumé.
        try FileManager.default.removeItem(at: list)
        let r4 = try await engine.apply(catalog, installer: installer)
        #expect(r4.status.lists["t"]?.cacheUsed != nil && r4.status.lists["t"]?.error != nil)
        #expect(r4.status.domainCounts["t"] == 3)
        #expect(r4.status.summary(for: ["t"])?.failed == 1)

        // Fichier d'état d'une version précédente : lisible, sans état par liste.
        let old = try JSONDecoder().decode(KidSafeStatus.self, from: Data(#"{"domainCounts":{"t":3},"failures":{},"warnings":{}}"#.utf8))
        #expect(old.lists.isEmpty && old.domainCounts["t"] == 3)
    }
}
