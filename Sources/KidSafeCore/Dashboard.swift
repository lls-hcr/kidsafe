import Foundation

/// Page HTML autonome du « mode détaillé » (aucun accès internet, aucune bibliothèque externe) :
/// tuiles, histogrammes en SVG, tableaux. Générée seulement au moment du clic.
public enum Dashboard {
    public struct Input: Sendable {
        public var counters: Monitor.Counters?
        public var domainsOnLists: Int
        public var summary: Monitor.Summary
        public var logEnabled: Bool
        public var version: String
        public var generatedAt = Date()
        public init(counters: Monitor.Counters?, domainsOnLists: Int, summary: Monitor.Summary, logEnabled: Bool, version: String) {
            self.counters = counters; self.domainsOnLists = domainsOnLists; self.summary = summary
            self.logEnabled = logEnabled; self.version = version
        }
    }

    public static func html(_ d: Input) -> String {
        let lang = Localization.currentLanguage
        let loc = Locale(identifier: lang)
        func time(_ date: Date, _ f: Date.FormatStyle) -> String { date.formatted(f.locale(loc)) }
        let c = d.counters
        let pct = c.map { String(format: "%.1f %%", locale: loc, $0.blockedPercent) } ?? "—"
        let since = c?.since.map { L("mon.since", time($0, .dateTime.day().month(.abbreviated).hour().minute())) } ?? ""

        var tiles = ""
        tiles += tile(L("mon.requests"), c.map { formatCount($0.requests) } ?? "—", since, "")
        tiles += tile(L("mon.blocked"), c.map { formatCount($0.blocked) } ?? "—", since, "hl")
        tiles += tile(L("mon.percent"), pct, since, "hl")
        tiles += tile(L("mon.domains"), formatCount(d.domainsOnLists), L("mon.domains.sub"), "")
        let logged = d.summary.perDay.map(\.count).reduce(0, +)
        tiles += tile(L("mon.logged7"), d.logEnabled ? formatCount(logged) : "—", L("mon.logged7.sub"), "")

        let s = d.summary
        let hourBars = s.perHour.map { (label: time($0.hour, .dateTime.hour()), value: $0.count) }
        let dayBars = s.perDay.map { (label: time($0.day, .dateTime.weekday(.abbreviated).day()), value: $0.count) }

        let stamp = time(d.generatedAt, .dateTime.day().month(.abbreviated).hour().minute())
        // Bouton « Actualiser » : demande à KidSafe de réécrire ce fichier (lien kidsafe://), puis recharge la page.
        var body = """
        <div class="snap"><span>\(esc(L("mon.snapshot", stamp)))</span>
        <a class="btn" href="kidsafe://dashboard/refresh" title="\(esc(L("mon.refresh.help")))"
           onclick="this.textContent='\(esc(L("mon.refreshing")))';setTimeout(function(){location.reload()},2500)">↻ \(esc(L("mon.refresh")))</a></div>
        <div class="tiles">\(tiles)</div>
        """
        if !d.logEnabled {
            body += "<p class=\"note\">\(esc(L("mon.logOff")))</p>"
        }
        body += """
        <div class="grid2">
          <section><h2>\(esc(L("mon.perHour")))</h2>\(bars(hourBars, every: 3))</section>
          <section><h2>\(esc(L("mon.perDay")))</h2>\(bars(dayBars, every: 1))</section>
        </div>
        <div class="grid2">
          <section><h2>\(esc(L("mon.top")))</h2>\(table(s.topDomains.map { ($0.host, $0.count) }, emptyText: L("mon.none")))</section>
          <section><h2>\(esc(L("mon.perCategory")))</h2>\(hbars(s.perCategory, emptyText: L("mon.none")))</section>
        </div>
        <p class="src">\(esc(L("mon.fromLog")))</p>
        <section><h2>\(esc(L("mon.recent")))</h2>\(recent(s.recent, time: { time($0, .dateTime.day().month(.abbreviated).hour().minute().second()) }))</section>
        """

        return """
        <!doctype html><html lang="\(lang)"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>KidSafe — \(esc(L("mon.title")))</title>
        <style>\(PageStyle.css)</style></head><body>
        \(PageStyle.header(title: esc(L("mon.title")),
                           meta: esc(L("mon.generated", time(d.generatedAt, .dateTime.day().month().year().hour().minute()))) + " · KidSafe " + esc(d.version)))
        <main>\(body)</main>
        <footer>\(esc(L("mon.footer")))</footer>
        </body></html>
        """
    }

    // MARK: - Éléments

    private static func tile(_ title: String, _ value: String, _ sub: String, _ cls: String) -> String {
        "<div class=\"tile \(cls)\"><div class=\"tt\">\(esc(title))</div><div class=\"tv\">\(esc(value))</div><div class=\"ts\">\(esc(sub))</div></div>"
    }

    /// Histogramme vertical en SVG ; la valeur s'affiche au survol et au-dessus des barres non nulles.
    private static func bars(_ data: [(label: String, value: Int)], every: Int) -> String {
        let w = 720.0, h = 200.0, top = 22.0, bottom = 26.0
        let maxV = max(1, data.map(\.value).max() ?? 1)
        let slot = w / Double(max(1, data.count)), bw = slot * 0.62
        var svg = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" class=\"chart\" role=\"img\">"
        svg += "<line x1=\"0\" y1=\"\(h - bottom)\" x2=\"\(w)\" y2=\"\(h - bottom)\" class=\"axis\"/>"
        for (i, d) in data.enumerated() {
            let bh = (h - top - bottom) * Double(d.value) / Double(maxV)
            let x = Double(i) * slot + (slot - bw) / 2, y = h - bottom - bh
            svg += "<rect x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(bw))\" height=\"\(f(max(bh, d.value > 0 ? 2 : 0)))\" rx=\"3\" class=\"bar\"><title>\(esc(d.label)) : \(d.value)</title></rect>"
            if d.value > 0, data.count <= 12 || bh > 14 {
                svg += "<text x=\"\(f(x + bw / 2))\" y=\"\(f(y - 5))\" class=\"val\">\(formatCount(d.value))</text>"
            }
            if i % every == 0 {
                svg += "<text x=\"\(f(x + bw / 2))\" y=\"\(f(h - 8))\" class=\"lbl\">\(esc(d.label))</text>"
            }
        }
        return svg + "</svg>"
    }

    private static func hbars(_ data: [(name: String, count: Int)], emptyText: String) -> String {
        guard let maxV = data.map(\.count).max(), maxV > 0 else { return "<p class=\"empty\">\(esc(emptyText))</p>" }
        return "<div class=\"hb\">" + data.map { d in
            "<div class=\"hbr\"><span class=\"hbn\">\(esc(d.name))</span><span class=\"hbt\"><span class=\"hbf\" style=\"width:\(f(Double(d.count) * 100 / Double(maxV)))%\"></span></span><span class=\"hbv\">\(formatCount(d.count))</span></div>"
        }.joined() + "</div>"
    }

    private static func table(_ rows: [(String, Int)], emptyText: String) -> String {
        guard let maxV = rows.map(\.1).max(), maxV > 0 else { return "<p class=\"empty\">\(esc(emptyText))</p>" }
        var t = "<table><thead><tr><th>\(esc(L("mon.col.domain")))</th><th class=\"n\">\(esc(L("mon.col.hits")))</th><th>\(esc(L("mon.col.freq")))</th></tr></thead><tbody>"
        for (host, n) in rows {
            t += "<tr><td class=\"dom\">\(esc(host))</td><td class=\"n\">\(formatCount(n))</td><td><span class=\"freq\"><span style=\"width:\(f(Double(n) * 100 / Double(maxV)))%\"></span></span></td></tr>"
        }
        return t + "</tbody></table>"
    }

    private static func recent(_ entries: [BlockLog.Entry], time: (Date) -> String) -> String {
        guard !entries.isEmpty else { return "<p class=\"empty\">\(esc(L("mon.none")))</p>" }
        var t = "<table><thead><tr><th>\(esc(L("mon.col.time")))</th><th>\(esc(L("mon.col.domain")))</th></tr></thead><tbody>"
        for e in entries { t += "<tr><td class=\"time\">\(esc(time(e.date)))</td><td class=\"dom\">\(esc(e.host))</td></tr>" }
        return t + "</tbody></table>"
    }

    private static func f(_ v: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v) }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

}
