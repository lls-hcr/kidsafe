import Foundation

private let hagezi = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/"
private let ut1 = "https://dsi.ut-capitole.fr/blacklists/download/"
private let stevenBlack = "https://raw.githubusercontent.com/StevenBlack/hosts/master/"
private let blp = "https://blocklistproject.github.io/Lists/alt-version/"

private func hz(_ file: String) -> Catalog.Source { .init(url: hagezi + file, license: "GPL-3.0 (HaGeZi)") }
private func u(_ cat: String) -> Catalog.Source {
    .init(url: ut1 + cat + ".tar.gz", archiveMember: cat + "/domains", license: "CC BY-SA 4.0 (UT1 Toulouse Capitole)")
}
private func oisd(_ list: String) -> Catalog.Source { .init(url: "https://\(list).oisd.nl/domainswild2", license: "GPL-3.0 (OISD)") }

/// Thème d'une liste principale : les listes sont présentées par thème dans l'onglet Listes.
public enum ListGroup: String, Codable, Sendable, CaseIterable {
    case adult, ads, security, bypass
    public var title: String { L("group." + rawValue) }
}

/// Taille d'une liste proposée en plusieurs versions (HaGeZi : mini, normale, complète).
public enum ListLevel: String, Codable, Sendable, CaseIterable {
    case light, normal, strong
    public var title: String { L("level." + rawValue) }
}

/// Fiche d'une liste connue (bouton ⓘ) : qui la maintient, à quel rythme, avec quel risque de blocage par erreur.
public struct ListInfo: Sendable {
    public enum Updates: Sendable, Equatable {
        case hourly, severalDaily, daily, weekly
        /// Plus mise à jour depuis cette date (clé de traduction du mois).
        case stale(String)
        public var text: String {
            switch self {
            case .hourly: return L("info.updates.hourly")
            case .severalDaily: return L("info.updates.severalDaily")
            case .daily: return L("info.updates.daily")
            case .weekly: return L("info.updates.weekly")
            case .stale(let since): return L("info.updates.stale", L(since))
            }
        }
    }
    public enum Risk: String, Sendable { case low, medium, high
        public var text: String { L("info.risk." + rawValue) }
    }

    public var maintainer: String
    public var homepage: String
    public var updates: Updates
    public var risk: Risk
    /// Taille approximative (relevée à la sortie de la version), pour une liste pas encore téléchargée.
    public var approxDomains: Int?
    /// Clé de traduction de la description.
    public var descriptionKey: String
    public var description: String { L(descriptionKey) }
}

public extension Catalog {
    /// Clé de traduction de l'avertissement de la liste UT1 complète.
    static let heavyUT1Warning = "warning.heavy.ut1"
    static let heavyTIFWarning = "warning.heavy.tif"

    /// Version du format du catalogue : 2 = listes présentées par thème, avec niveaux (0.7.4).
    static let currentVersion = 2

    /// Catalogue installé par défaut : les listes principales, par thème ; seule HaGeZi NSFW est cochée.
    /// Les autres thèmes (jeux d'argent, violence…) s'ajoutent depuis le menu « Ajouter une liste ».
    static var `default`: Catalog {
        Catalog(categories: mainLists, allowlist: [], strictMode: false, hardenPrivoxy: true, version: currentVersion)
    }

    private static var mainLists: [Category] { [
        .init(id: "adult", name: "Contenus pour adultes", enabled: true, sources: [hz("nsfw-onlydomains.txt")], group: .adult),
        .init(id: "adult-oisd", name: "Contenus pour adultes (OISD)", enabled: false, sources: [oisd("nsfw")], group: .adult),
        .init(id: "adult-ut1", name: "Contenus pour adultes, liste UT1 complète", enabled: false, sources: [u("adult")],
              warning: heavyUT1Warning, group: .adult),
        .init(id: "ads", name: "Publicité et pistage", enabled: false, sources: levelSources("ads", .light) ?? [],
              group: .ads, level: .light),
        .init(id: "ads-oisd", name: "Publicité, pistage et malware (OISD)", enabled: false, sources: [oisd("big")], group: .ads),
        .init(id: "security", name: "Arnaques, hameçonnage, logiciels malveillants", enabled: false,
              sources: levelSources("security", .light) ?? [], group: .security, level: .light),
        .init(id: "bypass", name: "Contournement : VPN, proxys, DNS chiffré", enabled: false,
              sources: [hz("doh-vpn-proxy-bypass-onlydomains.txt"), u("vpn"), u("doh")], group: .bypass),
    ] }

    /// Versions de chaque liste à niveaux : fichier HaGeZi et taille approximative.
    private static let levelFiles: [String: [ListLevel: (file: String, domains: Int)]] = [
        "ads": [.light: ("pro.mini-onlydomains.txt", 90_000), .normal: ("pro-onlydomains.txt", 236_000),
                .strong: ("pro.plus-onlydomains.txt", 249_000)],
        "security": [.light: ("tif.mini-onlydomains.txt", 191_000), .normal: ("tif.medium-onlydomains.txt", 373_000),
                     .strong: ("tif-onlydomains.txt", 2_010_000)],
    ]

    /// Sources d'une liste à niveaux pour ce niveau (nil si la liste n'a pas de niveaux).
    static func levelSources(_ id: String, _ level: ListLevel) -> [Source]? {
        levelFiles[id]?[level].map { [hz($0.file)] }
    }

    static func hasLevels(_ id: String) -> Bool { levelFiles[id] != nil }

    /// Avertissement à afficher pour ce niveau (liste très lourde pour Privoxy).
    static func levelWarning(_ id: String, _ level: ListLevel) -> String? {
        id == "security" && level == .strong ? heavyTIFWarning : nil
    }

    /// Niveau correspondant à une source déjà enregistrée (migration des anciens catalogues).
    static func level(of id: String, sources: [Source]) -> ListLevel? {
        guard let files = levelFiles[id] else { return nil }
        return ListLevel.allCases.first { l in sources.contains { $0.url == hagezi + (files[l]?.file ?? "") } }
    }

    // MARK: - Listes à ajouter

    /// Thèmes supplémentaires proposés dans « Ajouter une liste » (une fois ajoutés, supprimables).
    static var themeLibrary: [Category] { presets(themePresets) }
    /// Autres listes gratuites, pour les parents avertis.
    static var otherLibrary: [Category] { presets(otherPresets) }
    /// Toutes les listes que l'on peut ajouter depuis le menu (et `kidsafe-blocklist add-list --from-library`).
    static var library: [Category] { themeLibrary + otherLibrary }

    private static func presets(_ list: [Category]) -> [Category] {
        list.map { var c = $0; c.custom = true; c.name = L("library." + c.id); return c }
    }

    private static let themePresets: [Category] = [
        .init(id: "gambling", name: "Jeux d'argent", enabled: true, sources: [u("gambling")]),
        .init(id: "hagezi-gambling", name: "HaGeZi : jeux d'argent", enabled: true, sources: [hz("gambling-onlydomains.txt")]),
        .init(id: "violence", name: "Violence, haine", enabled: true, sources: [u("agressif")]),
        .init(id: "drugs", name: "Drogues", enabled: true, sources: [u("drogue")]),
        .init(id: "dating", name: "Sites de rencontre", enabled: true, sources: [u("dating")]),
        .init(id: "social", name: "Réseaux sociaux", enabled: true, sources: [u("social_networks")]),
        .init(id: "games", name: "Jeux en ligne", enabled: true, sources: [u("games")]),
        .init(id: "ut1-warez", name: "Téléchargement illégal", enabled: true, sources: [u("warez")]),
        .init(id: "ut1-shortener", name: "Raccourcisseurs d'adresses", enabled: true, sources: [u("shortener")]),
    ]

    private static let otherPresets: [Category] = [
        .init(id: "stevenblack", name: "StevenBlack Unified hosts", enabled: true,
              sources: [Source(url: stevenBlack + "hosts", license: "MIT")]),
        .init(id: "stevenblack-porn", name: "StevenBlack : contenus pour adultes", enabled: true,
              sources: [Source(url: stevenBlack + "alternates/porn-only/hosts", license: "MIT")]),
        .init(id: "stevenblack-gambling", name: "StevenBlack : jeux d'argent", enabled: true,
              sources: [Source(url: stevenBlack + "alternates/gambling-only/hosts", license: "MIT")]),
        .init(id: "easylist", name: "EasyList", enabled: true,
              sources: [Source(url: "https://easylist.to/easylist/easylist.txt", license: "GPL-3.0 / CC BY-SA 3.0")]),
        .init(id: "easyprivacy", name: "EasyPrivacy", enabled: true,
              sources: [Source(url: "https://easylist.to/easylist/easyprivacy.txt", license: "GPL-3.0 / CC BY-SA 3.0")]),
        .init(id: "liste-fr", name: "Liste FR", enabled: true,
              sources: [Source(url: "https://easylist-downloads.adblockplus.org/liste_fr.txt", license: "GPL-3.0")]),
        .init(id: "hagezi-apple", name: "HaGeZi : télémétrie Apple", enabled: true, sources: [hz("native.apple-onlydomains.txt")]),
        .init(id: "hagezi-microsoft", name: "HaGeZi : télémétrie Microsoft", enabled: true, sources: [hz("native.winoffice-onlydomains.txt")]),
    ]

    // MARK: - Fiches ⓘ

    /// Fiche d'une liste connue ; nil pour une liste ajoutée par le parent depuis une adresse ou un fichier.
    static func info(for id: String, level: ListLevel? = nil) -> ListInfo? {
        let hzHome = "https://github.com/hagezi/dns-blocklists", ut1Home = "https://dsi.ut-capitole.fr/blacklists/"
        let ut1Name = "Université Toulouse Capitole (UT1)", sbHome = "https://github.com/StevenBlack/hosts"
        func hzInfo(_ risk: ListInfo.Risk, _ n: Int?) -> ListInfo {
            ListInfo(maintainer: "HaGeZi", homepage: hzHome, updates: .severalDaily, risk: risk, approxDomains: n, descriptionKey: "info." + id)
        }
        func ut1Info(_ risk: ListInfo.Risk, _ n: Int? = nil) -> ListInfo {
            ListInfo(maintainer: ut1Name, homepage: ut1Home, updates: .daily, risk: risk, approxDomains: n, descriptionKey: "info." + id)
        }
        func other(_ who: String, _ home: String, _ up: ListInfo.Updates, _ risk: ListInfo.Risk, _ n: Int?) -> ListInfo {
            ListInfo(maintainer: who, homepage: home, updates: up, risk: risk, approxDomains: n, descriptionKey: "info." + id)
        }
        let levelSize = level.flatMap { levelFiles[id]?[$0]?.domains }
        switch id {
        case "adult": return hzInfo(.low, 82_000)
        case "adult-oisd": return other("OISD (Stephan van Ruth)", "https://oisd.nl", .hourly, .low, 499_000)
        case "adult-ut1": return ut1Info(.medium, 4_600_000)
        case "ads": return hzInfo(level == .strong ? .medium : .low, levelSize)
        case "ads-oisd": return other("OISD (Stephan van Ruth)", "https://oisd.nl", .hourly, .low, 221_000)
        case "security": return hzInfo(.low, levelSize)
        case "bypass": return hzInfo(.medium, 24_000)
        case "hagezi-gambling": return hzInfo(.low, nil)
        case "hagezi-apple", "hagezi-microsoft": return hzInfo(.medium, id == "hagezi-apple" ? 105 : 395)
        case "gambling", "violence", "drugs", "dating", "social", "games", "ut1-warez", "ut1-shortener": return ut1Info(.medium)
        case "stevenblack": return other("Steven Black", sbHome, .weekly, .low, 80_000)
        case "stevenblack-porn", "stevenblack-gambling": return other("Steven Black", sbHome, .weekly, .low, nil)
        case "easylist", "easyprivacy": return other("EasyList", "https://easylist.to", .severalDaily, .low, nil)
        case "liste-fr": return other("Liste FR", "https://github.com/easylist/listefr", .daily, .low, nil)
        case "blp-drugs", "blp-scam", "blp-tiktok":
            return other("Block List Project", "https://github.com/blocklistproject/Lists", .stale("month.2026-07"), .high, nil)
        default: return nil
        }
    }

    // MARK: - Migration

    /// Met à jour un catalogue enregistré par une version précédente. Rien ne se décoche :
    /// - les listes principales gardent leur état (coché ou non) et reçoivent leur thème et leur niveau ;
    /// - les nouvelles listes principales (OISD) arrivent décochées ;
    /// - un ancien thème coché (jeux d'argent, violence…) devient une liste ajoutée, toujours cochée ;
    ///   décoché, il disparaît de la fenêtre et reste disponible dans le menu « Ajouter une liste » ;
    /// - les listes ajoutées par le parent restent telles quelles.
    /// Renvoie vrai si le catalogue a changé.
    @discardableResult
    mutating func migrate() -> Bool {
        guard (version ?? 1) < Self.currentVersion else { return false }
        let old = categories
        var result: [Category] = []
        for var c in Self.mainLists {
            if let o = old.first(where: { $0.id == c.id && $0.custom != true }) {
                c.enabled = o.enabled
                if let l = Self.level(of: c.id, sources: o.sources) {
                    c.level = l
                    c.sources = Self.levelSources(c.id, l) ?? c.sources
                    c.warning = Self.levelWarning(c.id, l)
                }
            }
            result.append(c)
        }
        let themes = Self.themeLibrary
        for o in old where !result.contains(where: { $0.id == o.id }) {
            if o.custom == true {
                result.append(o)
            } else if o.enabled, var t = themes.first(where: { $0.id == o.id }) {
                t.enabled = true
                result.append(t)
            }
        }
        categories = result
        version = Self.currentVersion
        return true
    }
}
