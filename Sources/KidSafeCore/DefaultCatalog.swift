import Foundation

private let hagezi = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/"
private let ut1 = "https://dsi.ut-capitole.fr/blacklists/download/"
private let stevenBlack = "https://raw.githubusercontent.com/StevenBlack/hosts/master/"
private let blp = "https://blocklistproject.github.io/Lists/alt-version/"

private func hz(_ file: String) -> Catalog.Source { .init(url: hagezi + file, license: "GPL-3.0 (HaGeZi)") }
private func u(_ cat: String) -> Catalog.Source {
    .init(url: ut1 + cat + ".tar.gz", archiveMember: cat + "/domains", license: "CC BY-SA 4.0 (UT1 Toulouse Capitole)")
}

public extension Catalog {
    /// Clé de traduction de l'avertissement de la liste UT1 complète.
    static let heavyUT1Warning = "warning.heavy.ut1"

    /// Catalogue installé par défaut : seule la catégorie « Contenus pour adultes » est active.
    static let `default` = Catalog(categories: [
        .init(id: "adult", name: "Contenus pour adultes", enabled: true, sources: [hz("nsfw-onlydomains.txt")]),
        .init(id: "adult-ut1", name: "Contenus pour adultes, liste UT1 complète", enabled: false, sources: [u("adult")],
              warning: heavyUT1Warning),
        .init(id: "bypass", name: "Contournement : VPN, proxys, DNS chiffré", enabled: false,
              sources: [hz("doh-vpn-proxy-bypass-onlydomains.txt"), u("vpn"), u("doh")]),
        .init(id: "security", name: "Arnaques, hameçonnage, logiciels malveillants", enabled: false, sources: [hz("tif.mini-onlydomains.txt")]),
        .init(id: "gambling", name: "Jeux d'argent", enabled: false, sources: [u("gambling")]),
        .init(id: "violence", name: "Violence, haine", enabled: false, sources: [u("agressif")]),
        .init(id: "drugs", name: "Drogues", enabled: false, sources: [u("drogue")]),
        .init(id: "dating", name: "Sites de rencontre", enabled: false, sources: [u("dating")]),
        .init(id: "social", name: "Réseaux sociaux", enabled: false, sources: [u("social_networks")]),
        .init(id: "games", name: "Jeux en ligne", enabled: false, sources: [u("games")]),
        .init(id: "ads", name: "Publicité et pistage", enabled: false, sources: [hz("pro.mini-onlydomains.txt")]),
    ], allowlist: [], strictMode: false, hardenPrivoxy: true)

    /// Listes gratuites proposées dans « Ajouter une liste » ; le parent peut aussi saisir n'importe quelle URL.
    /// Une fois ajoutée, une liste est téléchargée, convertie et installée au prochain `update`.
    static var library: [Category] {
        libraryPresets.map { var c = $0; c.custom = true; c.name = L("library." + c.id); return c }
    }

    private static let libraryPresets: [Category] = [
        Category(id: "easylist", name: "EasyList (publicité, règles de domaine seulement)", enabled: true,
              sources: [Source(url: "https://easylist.to/easylist/easylist.txt", license: "GPL-3.0 / CC BY-SA 3.0")]),
        Category(id: "easyprivacy", name: "EasyPrivacy (pistage)", enabled: true,
              sources: [Source(url: "https://easylist.to/easylist/easyprivacy.txt", license: "GPL-3.0 / CC BY-SA 3.0")]),
        Category(id: "liste-fr", name: "Liste FR (publicité, sites francophones)", enabled: true,
              sources: [Source(url: "https://easylist-downloads.adblockplus.org/liste_fr.txt", license: "GPL-3.0")]),
        Category(id: "stevenblack", name: "StevenBlack Unified hosts (publicité + malware)", enabled: true,
              sources: [Source(url: stevenBlack + "hosts", license: "MIT")]),
        Category(id: "stevenblack-porn", name: "StevenBlack : contenus pour adultes", enabled: true,
              sources: [Source(url: stevenBlack + "alternates/porn-only/hosts", license: "MIT")]),
        Category(id: "stevenblack-gambling", name: "StevenBlack : jeux d'argent", enabled: true,
              sources: [Source(url: stevenBlack + "alternates/gambling-only/hosts", license: "MIT")]),
        Category(id: "hagezi-gambling", name: "HaGeZi : jeux d'argent (complète)", enabled: true, sources: [hz("gambling-onlydomains.txt")]),
        Category(id: "blp-drugs", name: "Block List Project : drogues", enabled: true,
              sources: [Source(url: blp + "drugs-nl.txt", license: "Unlicense")]),
        Category(id: "blp-scam", name: "Block List Project : arnaques", enabled: true,
              sources: [Source(url: blp + "scam-nl.txt", license: "Unlicense")]),
        Category(id: "blp-tiktok", name: "Block List Project : TikTok", enabled: true,
              sources: [Source(url: blp + "tiktok-nl.txt", license: "Unlicense")]),
        Category(id: "ut1-warez", name: "UT1 : téléchargement illégal", enabled: true, sources: [u("warez")]),
        Category(id: "ut1-shortener", name: "UT1 : raccourcisseurs d'URL", enabled: true, sources: [u("shortener")]),
    ]
}
