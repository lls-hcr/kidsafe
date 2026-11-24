import AppKit
import KidSafeCore
import SwiftUI
import WebKit

/// Captures d'écran du guide : l'app dessine ses propres vues (données de démonstration) dans des
/// fenêtres hors écran et les enregistre en PNG. Aucune autorisation d'enregistrement d'écran n'est nécessaire.
///   KIDSAFE_SCREENSHOTS=<dossier> KIDSAFE_LANG=fr KidSafe.app/Contents/MacOS/KidSafe
@MainActor
struct Screenshotter {
    let model: AppModel

    func run(into dir: URL) {
        if let lang = ProcessInfo.processInfo.environment["KIDSAFE_LANG"] { Localization.forcedLanguage = lang }
        NSApp.setActivationPolicy(.regular)   // pour que les fenêtres de capture puissent être actives
        NSApp.activate(ignoringOtherApps: true)
        model.loadDemoState()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        shoot(AnyView(MenuShot()), "menu", width: 330, into: dir)
        shoot(AnyView(BlockSplashView(site: "pokerstars.com", reason: L("category.gambling")).padding(14)
                        .background(Color(nsColor: .windowBackgroundColor))), "splash", width: 448, into: dir)
        shoot(AnyView(TabShot { Form { Section(L("app.general.protection")) { BlockMessageSetting() } }.formStyle(.grouped).toggleStyle(ColorSwitchStyle()) }),
              "block-setting", width: 620, height: 200, into: dir)
        windowShot(tab: 0, "lists", into: dir)
        if let sec = model.catalog.categories.first(where: { $0.id == "security" }) {
            shoot(AnyView(ListInfoView(category: sec).background(Color(nsColor: .windowBackgroundColor))), "list-info", width: 360, into: dir)
        }
        windowShot(tab: 1, "social", into: dir)
        windowShot(tab: 2, "domains", into: dir)
        windowShot(tab: 3, "general", into: dir)
        windowShot(tab: 4, "advanced", into: dir)
        shoot(AnyView(MonitorView().background(Color(nsColor: .windowBackgroundColor))), "monitor", width: 340, into: dir)
        dashboard(into: dir)
        model.loadDemoProtection()   // en dernier : mot de passe de démonstration (le menu ci-dessus n'en a pas)
        windowShot(tab: 3, "protection", scrollTo: "protection", keepTop: 372, into: dir)
    }

    /// Fenêtre de réglages complète, comme une capture de l'écran : barre de titre, onglets, pied de page,
    /// coins arrondis. `keepTop` : hauteur gardée (en points, depuis le haut), pour une seule section.
    private func windowShot(tab: Int, _ name: String, scrollTo: String? = nil, keepTop: CGFloat? = nil, into dir: URL) {
        // Même construction que la vraie fenêtre (AppDelegate.showSettings).
        let controller = NSHostingController(rootView: SettingsView(tab: tab, generalScrollTarget: scrollTo).environmentObject(model)
                                                .environment(\.colorScheme, .light).environment(\.controlActiveState, .key))
        let w = KeyWindow(contentViewController: controller)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.appearance = NSAppearance(named: .aqua)
        w.title = L("app.settings")
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        w.makeFirstResponder(nil)   // pas de curseur clignotant dans un champ de texte
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        if ProcessInfo.processInfo.environment["KIDSAFE_SHOTS_DEBUG"] != nil { print(name, "key:", w.isKeyWindow, "app active:", NSApp.isActive, w.frame) }
        guard let frame = w.contentView?.superview else { return }   // cadre de la fenêtre, barre de titre comprise
        frame.display()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        w.orderOut(nil)
        guard let full = rep.cgImage else { return }
        let scale = CGFloat(full.width) / frame.bounds.width
        let keep = min(CGFloat(full.height), (keepTop ?? frame.bounds.height) * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: full.width, height: Int(keep), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let r = 16 * scale
        // Coins arrondis en haut ; en bas seulement si la fenêtre est entière (sinon le cadre déborde sous l'image).
        let below = keepTop == nil ? 0 : r * 2
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: -below, width: CGFloat(full.width), height: keep + below),
                           cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
        // L'app dessine hors écran sans être au premier plan ; trois éléments manquent alors dans la capture :
        // - la barre d'onglets n'est qu'un voile transparent (8 % de noir) sans le fond de la fenêtre dessous ;
        // - l'onglet choisi y laisse un trou transparent, sans son nom ;
        // - les boutons de la barre de titre sont gris.
        // On les complète, aux positions réelles. En pixels, lignes comptées depuis le haut.
        let tabs = Self.firstSubview(of: frame, NSTabView.self)
        let toFrame: (NSView) -> CGRect = { v in
            let r = v.convert(v.bounds, to: frame)
            return frame.isFlipped ? CGRect(x: r.minX, y: frame.bounds.height - r.maxY, width: r.width, height: r.height) : r
        }
        var strip: (x0: Int, x1: Int, y0: Int, y1: Int)?, hole: (x0: Int, x1: Int, y0: Int, y1: Int)?
        func grow(_ b: inout (x0: Int, x1: Int, y0: Int, y1: Int)?, _ x: Int, _ y: Int) {
            b = b.map { (min($0.x0, x), max($0.x1, x), min($0.y0, y), max($0.y1, y)) } ?? (x, x, y, y)
        }
        if let tabs {
            let top = Int(((frame.bounds.height - toFrame(tabs).maxY) * scale).rounded())   // bord haut de NSTabView
            let margin = Int(r) + 4
            for y in max(0, top - Int(30 * scale))..<min(rep.pixelsHigh, top + Int(30 * scale)) {
                for x in margin..<(rep.pixelsWide - margin) {
                    let a = rep.colorAt(x: x, y: y)?.alphaComponent ?? 1
                    if a < 0.99 { grow(&strip, x, y) }
                    if a < 0.01 { grow(&hole, x, y) }
                }
            }
        }
        let cgY = { (row: Int) -> CGFloat in keep - CGFloat(row) - 1 }   // ligne de pixel → y de CGContext
        if let s = strip {
            // Fond sous la barre : celui de la même ligne, juste à droite (blanc en haut, gris du cadre en bas).
            for y in s.y0...s.y1 {
                let c = rep.colorAt(x: s.x1 + 8, y: y).flatMap { $0.alphaComponent > 0.99 ? $0.cgColor : nil } ?? CGColor(gray: 1, alpha: 1)
                ctx.setFillColor(c)
                ctx.fill(CGRect(x: CGFloat(s.x0), y: cgY(y), width: CGFloat(s.x1 - s.x0 + 1), height: 1))
            }
        }
        ctx.draw(full, in: CGRect(x: 0, y: keep - CGFloat(full.height), width: CGFloat(full.width), height: CGFloat(full.height)))
        if let h = hole, let tabs, let label = tabs.selectedTabViewItem?.label {
            let box = CGRect(x: CGFloat(h.x0), y: cgY(h.y1), width: CGFloat(h.x1 - h.x0 + 1), height: CGFloat(h.y1 - h.y0 + 1))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.078)); ctx.fill(box)   // voile de la barre sous les coins
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -scale / 2), blur: 2 * scale, color: CGColor(gray: 0, alpha: 0.15))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(CGPath(roundedRect: box.insetBy(dx: scale, dy: scale), cornerWidth: 7 * scale, cornerHeight: 7 * scale, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
            let font = NSFont(descriptor: tabs.font.fontDescriptor, size: tabs.font.pointSize * scale) ?? tabs.font
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor(white: 0, alpha: 0.85)])   // couleur fixe : le Mac peut être en mode sombre
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.translateBy(x: 0, y: keep - CGFloat(full.height))
        ctx.scaleBy(x: scale, y: scale)
        for (kind, color) in [(NSWindow.ButtonType.closeButton, (255, 95, 87)), (.miniaturizeButton, (254, 188, 46))] {
            guard let b = w.standardWindowButton(kind) else { continue }
            let r = toFrame(b)
            let d = min(r.width, r.height) - 1, c = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
            ctx.fillEllipse(in: c)
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: c.insetBy(dx: 0.25, dy: 0.25))
        }
        guard let out = ctx.makeImage() else { return }
        let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        try? png?.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// Fenêtre hors écran + cacheDisplay : rendu réel des contrôles AppKit, en apparence claire.
    private func shoot(_ view: AnyView, _ name: String, width: CGFloat, height: CGFloat? = nil, into dir: URL) {
        let host = NSHostingView(rootView: view.environmentObject(model).environment(\.colorScheme, .light)
                                    .environment(\.controlActiveState, .key))
        host.appearance = NSAppearance(named: .aqua)
        let size = CGSize(width: width, height: height ?? host.fittingSize.height)
        let w = KeyWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = host
        // Fenêtre active : sinon macOS dessine les interrupteurs et boutons en gris.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))   // laisse SwiftUI terminer le rendu
        if ProcessInfo.processInfo.environment["KIDSAFE_SHOTS_DEBUG"] != nil { print(name, "key:", w.isKeyWindow, "app active:", NSApp.isActive) }
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        w.orderOut(nil)
    }

    private static func firstSubview<T: NSView>(of view: NSView, _ type: T.Type) -> T? {
        for v in view.subviews {
            if let t = v as? T { return t }
            if let t = firstSubview(of: v, type) { return t }
        }
        return nil
    }

    /// Page détaillée du moniteur, rendue par WebKit avec un journal de démonstration.
    private func dashboard(into dir: URL) {
        let now = Date()
        let hosts = ["www.tiktok.com": 129, "m.youtube.com": 101, "roblox.com": 47, "adult-site.example": 21, "casino.example": 14, "ads.example": 9]
        var entries: [BlockLog.Entry] = []
        var rng = SystemRandomNumberGenerator()
        for (h, n) in hosts { for _ in 0..<n {
            let ago = TimeInterval(Int.random(in: 0..<(Bool.random(using: &rng) ? 86_400 : 6 * 86_400), using: &rng))
            entries.append(.init(date: now.addingTimeInterval(-ago), target: h, host: h))
        } }
        var summary = Monitor.summarize(entries, index: nil, now: now)
        summary.perCategory = [(L("category.adult"), 139), ("TikTok", 129), ("YouTube", 101), (L("action.reason.custom").prefix(1).uppercased() + L("action.reason.custom").dropFirst(), 47)]
        let html = Dashboard.html(.init(counters: model.monitorCounters, domainsOnLists: 413_289, summary: summary, logEnabled: true, version: model.appVersion))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        web.appearance = NSAppearance(named: .aqua)
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = web
        w.orderFrontRegardless()
        web.loadHTMLString(html, baseURL: nil)
        let end = Date().addingTimeInterval(5)
        while web.isLoading && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        var done = false
        web.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("dashboard.png"))
            }
            done = true
        }
        while !done && Date() < end.addingTimeInterval(5) { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        w.orderOut(nil)
    }
}

/// Le menu de la barre de menus, avec le fond arrondi d'une fenêtre de menu.
private struct MenuShot: View {
    var body: some View {
        MenuView()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
    }
}

/// Contenu d'un onglet des réglages, dans le cadre de la fenêtre.
private struct TabShot<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Fenêtre sans bordure qui peut devenir active (couleurs des contrôles comme à l'écran).
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Les contrôles AppKit se dessinent en couleur seulement dans une fenêtre active.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    // Reste hors de l'écran (macOS ramène sinon une fenêtre à barre de titre sur l'écran).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
