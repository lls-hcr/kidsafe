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
        shoot(AnyView(TabShot { ListsTab() }), "lists", width: 620, height: 560, into: dir)
        shoot(AnyView(TabShot { SocialTab() }), "social", width: 620, height: 560, into: dir)
        shoot(AnyView(TabShot { DomainsTab() }), "domains", width: 620, height: 300, into: dir)
        shoot(AnyView(TabShot { GeneralTab() }), "general", width: 620, height: 560, into: dir)
        shoot(AnyView(TabShot { AdvancedTab() }), "advanced", width: 620, height: 520, into: dir)
        shoot(AnyView(MonitorView().background(Color(nsColor: .windowBackgroundColor))), "monitor", width: 340, into: dir)
        dashboard(into: dir)
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
}
