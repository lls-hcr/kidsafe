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
        \(PageStyle.header(title: Dashboard.esc(L("guide.title")),
                           meta: Dashboard.esc(version.hasPrefix("KidSafe") ? version : "KidSafe " + version)))
        <main class="guide">\(body)</main>
        <footer>\(Dashboard.esc(L("guide.footer")))</footer>
        <div id="zoom" hidden><figure><img alt=""><p></p></figure></div>
        <script>
        // Captures en vignettes : un clic les agrandit, un autre clic (ou Échap) referme.
        (function () {
          var z = document.getElementById('zoom'), zi = z.querySelector('img'), zp = z.querySelector('p');
          document.querySelectorAll('figure.shot img').forEach(function (i) { i.title = \(jsString(L("guide.zoom"))); });
          document.addEventListener('click', function (e) {
            var t = e.target;
            if (t.matches && t.matches('figure.shot img')) {
              zi.src = t.src;
              zi.style.width = Math.min(t.naturalWidth / 2, window.innerWidth * 0.94) + 'px';   // captures en 2× : taille réelle
              var c = t.closest('figure').querySelector('figcaption');
              zp.textContent = c ? c.textContent : ''; z.hidden = false;
            } else if (!z.hidden) { z.hidden = true; }
          });
          document.addEventListener('keydown', function (e) { if (e.key === 'Escape') z.hidden = true; });
        })();
        </script>
        </body></html>
        """
    }

    /// Texte JavaScript entre guillemets (échappé).
    static func jsString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Remplace {{shot:nom}} par la capture, intégrée à la page : le guide reste un fichier unique,
    /// lisible sans connexion. Ordre : vraie capture de l'app (shot-<langue>-<nom>.jpg), puis capture
    /// générée (shot-<langue>-<nom>.png), puis la version anglaise. Capture absente : figure retirée.
    static func insertScreenshots(_ html: String, lang: String) -> String {
        var out = html
        while let r = out.range(of: #"\{\{shot:([a-z\-]+)\}\}"#, options: .regularExpression) {
            let name = String(out[r].dropFirst(7).dropLast(2))
            let file = [lang, "en"].lazy.flatMap { l in ["jpg", "png"].lazy.map { (l, $0) } }
                .compactMap { l, ext in Localization.bundle.url(forResource: "shot-\(l)-\(name)", withExtension: ext) }.first
            if let file, let data = try? Data(contentsOf: file) {
                let mime = file.pathExtension == "jpg" ? "image/jpeg" : "image/png"
                out.replaceSubrange(r, with: "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(name)\" loading=\"lazy\">")
            } else {
                out.replaceSubrange(r, with: "")
            }
        }
        return out.replacingOccurrences(of: #"<figure class="shot( small| wide)?"><figcaption>[^<]*</figcaption></figure>"#,
                                        with: "", options: .regularExpression)
    }
}
