import Foundation

/// Guide d'utilisation : contenu dans Resources/guide-fr.html et guide-en.html, assemblé avec le style
/// commun dans la langue de l'app. Page locale autonome, ouverte dans le navigateur.
public enum UserGuide {
    public static func html(version: String) -> String? {
        let lang = Localization.currentLanguage.hasPrefix("fr") ? "fr" : "en"
        guard let url = Localization.bundle.url(forResource: "guide-\(lang)", withExtension: "html"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let body = insertScreenshots(raw, lang: lang)
        return """
        <!doctype html><html lang="\(lang)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>KidSafe — \(Dashboard.esc(L("guide.title")))</title>
        <style>\(PageStyle.css)</style></head><body class="guide-page">
        \(PageStyle.header(title: Dashboard.esc(L("guide.title")), meta: "KidSafe " + Dashboard.esc(version)))
        <main class="guide">\(body)</main>
        <footer>\(Dashboard.esc(L("guide.footer")))</footer>
        </body></html>
        """
    }

    /// Remplace {{shot:nom}} par la capture (Resources/shot-<langue>-<nom>.png), intégrée à la page :
    /// le guide reste un fichier unique, lisible sans connexion. Capture absente : figure retirée.
    static func insertScreenshots(_ html: String, lang: String) -> String {
        var out = html
        while let r = out.range(of: #"\{\{shot:([a-z\-]+)\}\}"#, options: .regularExpression) {
            let name = String(out[r].dropFirst(7).dropLast(2))
            let file = Localization.bundle.url(forResource: "shot-\(lang)-\(name)", withExtension: "png")
                ?? Localization.bundle.url(forResource: "shot-en-\(name)", withExtension: "png")
            if let file, let data = try? Data(contentsOf: file) {
                out.replaceSubrange(r, with: "<img src=\"data:image/png;base64,\(data.base64EncodedString())\" alt=\"\(name)\" loading=\"lazy\">")
            } else {
                out.replaceSubrange(r, with: "")
            }
        }
        return out.replacingOccurrences(of: #"<figure class="shot( small)?"><figcaption>[^<]*</figcaption></figure>"#,
                                        with: "", options: .regularExpression)
    }
}
