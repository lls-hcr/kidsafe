import AppKit
import Combine
import KidSafeCore
import SwiftUI

@main
struct KidSafeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(delegate.model)
        } label: {
            MenuBarIcon().environmentObject(delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Image(systemName: model.isProtected ? "checkmark.shield.fill" : "exclamationmark.shield")
    }
}

/// Fenêtre de réglages gérée par AppKit : elle s'ouvre au premier lancement et à chaque
/// double-clic sur l'app (l'icône de la barre de menus peut être masquée si la barre est pleine).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?
    private let settingsTab = TabChoice(0)
    private var settingsLanguageWatch: AnyCancellable?
    private var monitorPanel: NSPanel?
    private var monitorTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["KIDSAFE_SCREENSHOTS"] {
            Screenshotter(model: model).run(into: URL(fileURLWithPath: dir))
            exit(0)
        }
        // Pas de fenêtre au lancement : KidSafe vit dans la barre de menus.
        // Un double-clic sur l'app déjà ouverte affiche les réglages (applicationShouldHandleReopen).
        model.openSettingsHandler = { [weak self] in self?.showSettings() }
        model.openMonitorHandler = { [weak self] in self?.showMonitor() }
        model.monitorPinHandler = { [weak self] pinned in self?.applyPin(pinned) }
        model.startUp()
        // Diagnostic (KIDSAFE_MONITOR_SELFTEST) : lit les compteurs depuis l'app, les affiche et quitte.
        if ProcessInfo.processInfo.environment["KIDSAFE_MONITOR_SELFTEST"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if let e = model.endpoint, let c = await Monitor.counters(host: e.host, port: e.port) {
                    print("COMPTEURS port \(e.port) : \(c.blocked) bloquées / \(c.requests) requêtes")
                } else {
                    print("COMPTEURS indisponibles")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Liens kidsafe:// (bouton « Actualiser » de la page détaillée) :
    ///   kidsafe://dashboard/refresh → régénère la page sur place ; kidsafe://dashboard → la régénère et l'ouvre.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "kidsafe" && url.host?.lowercased() == "dashboard" {
            model.openDashboard(open: url.path != "/refresh")
        }
    }

    /// Quitter retire le proxy puis arrête Privoxy (voir AppModel.shutDown).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shutDown()
        return .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Fenêtre flottante du moniteur ; ses chiffres ne sont rafraîchis que pendant qu'elle est ouverte.
    func showMonitor() {
        if monitorPanel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            p.contentViewController = NSHostingController(rootView: MonitorView().environmentObject(model))
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false          // reste visible quand on travaille dans une autre app
            p.setFrameAutosaveName("KidSafeMonitor")
            if !p.setFrameUsingName("KidSafeMonitor") { p.center() }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.monitorTimer?.invalidate(); self?.monitorTimer = nil }
            }
            monitorPanel = p
        }
        monitorPanel?.title = L("mon.title")
        applyPin(model.monitorPinned)
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshMonitor() }
        }
        NSApp.activate(ignoringOtherApps: true)
        monitorPanel?.makeKeyAndOrderFront(nil)
    }

    private func applyPin(_ pinned: Bool) {
        monitorPanel?.level = pinned ? .floating : .normal
        monitorPanel?.isFloatingPanel = pinned
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
            settingsWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow(scrollTo: String? = nil) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(selection: settingsTab, generalScrollTarget: scrollTo)
                                                                        .environmentObject(model)))
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.title = L("app.settings")
        if settingsLanguageWatch == nil {
            // receive(on:) : la nouvelle langue est appliquée (didSet) avant de recréer la fenêtre.
            settingsLanguageWatch = model.$language.dropFirst().removeDuplicates().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.rebuildSettingsWindow() }
        }
        return w
    }

    /// Changement de langue : la fenêtre est recréée au même endroit, sur le même onglet (le choix de la langue
    /// reste visible dans Général). Reconstruire
    /// le TabView dans la fenêtre ouverte empilait les noms des onglets au milieu de la barre.
    private func rebuildSettingsWindow() {
        guard let old = settingsWindow else { return }
        let w = makeSettingsWindow(scrollTo: settingsTab.tab == 3 ? "language" : nil)
        w.setFrame(old.frame, display: false)
        settingsWindow = w
        if old.isVisible { w.makeKeyAndOrderFront(nil) }
        old.orderOut(nil)
    }
}

// MARK: - Fenêtre de la barre de menus

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    /// Fenêtre du menu, pour la refermer avant d'ouvrir une autre fenêtre.
    @StateObject private var panel = WindowRef()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                StatusHeader()
                Spacer()
                if model.hasPassword {
                    Button { if model.isLocked { _ = model.requireUnlock() } else { model.lock() } } label: {
                        Image(systemName: model.isLocked ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.borderless)
                    .help(model.isLocked ? L("app.lock.unlock") : L("app.lock.lockNow"))
                }
            }

            Toggle(isOn: Binding(get: { model.catalog.filteringEnabled }, set: { model.setFiltering($0) })) {
                Text(L("app.menu.filtering")).font(.headline)
            }
            .toggleStyle(StateSwitchStyle())
            .disabled(model.installer == nil)

            if model.catalog.filteringEnabled {
                PauseMenu().disabled(model.installer == nil)
            }

            Summary()

            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text(L("app.login.toggle")).font(.callout)
            }
            .toggleStyle(.checkbox)

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(4).textSelection(.enabled)
            }

            Divider()
            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: L("app.updateNow"), symbol: "arrow.clockwise", busy: model.isApplying) { model.refreshListsManually() }
                    .disabled(model.isApplying || model.installer == nil || !model.catalog.filteringEnabled)
                MenuRow(title: L("app.menu.settings"), symbol: "gearshape") { panel.close(); model.openSettings() }
                MenuRow(title: L("mon.menu"), symbol: "gauge.with.dots.needle.33percent") { panel.close(); model.openMonitor() }
                MenuRow(title: L("app.menu.testPrivoxy"), symbol: "stethoscope") { panel.close(); model.openPrivoxyTestPage() }
                MenuRow(title: L("guide.menu"), symbol: "book") { panel.close(); model.openGuide() }
                if model.canSendFeedback { FeedbackRow(panel: panel) }
                if model.websiteURL != nil {
                    MenuRow(title: L("app.menu.website"), symbol: "globe") { panel.close(); model.open(model.websiteURL) }
                }
                if model.sourceURL != nil {
                    MenuRow(title: L("app.menu.source"), symbol: "chevron.left.forwardslash.chevron.right") { panel.close(); model.open(model.sourceURL) }
                }
                if model.donateURL != nil {
                    MenuRow(title: L("app.donate"), symbol: "heart") { panel.close(); model.donate() }
                }
                if model.isInstallingUpdate {
                    MenuRow(title: L("autoupdate.installing"), symbol: "arrow.down.app", busy: true) {}
                } else if let update = model.availableUpdate {
                    MenuRow(title: L("updates.menuAvailable", update.version), symbol: "sparkles") { panel.close(); model.offerUpdate(update) }
                }
                if model.canCheckUpdates {
                    MenuRow(title: L("app.checkUpdates"), symbol: "arrow.down.circle", busy: model.isCheckingUpdates) {
                        panel.close(); model.checkForUpdates()
                    }
                }
                Divider().padding(.vertical, 4)
                MenuRow(title: L("app.quit"), symbol: "power") { model.quit() }
                Text(model.versionLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(WindowReader(ref: panel))
        .onAppear { model.refreshSystemStatus() }
    }
}

/// Résumé de ce qui est bloqué.
struct Summary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !model.catalog.filteringEnabled, let until = model.catalog.pausedUntil {
                // Compte à rebours, rafraîchi chaque seconde.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Label(L("app.menu.pausedUntil", formatDate(until, date: .omitted, time: .shortened),
                            remainingLabel(until.timeIntervalSince(ctx.date))), systemImage: "timer")
                        .foregroundStyle(.orange).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !model.catalog.filteringEnabled {
                Label(L("app.menu.paused"), systemImage: "pause.circle").foregroundStyle(.orange)
            } else if model.catalog.strictMode {
                Label(L("app.strict.active", model.catalog.allowlist.count), systemImage: "lock.fill")
            } else {
                Label(L("app.menu.categories", model.enabledCount), systemImage: "list.bullet")
                let social = model.blockedServicesNow
                Label(social.isEmpty ? L("app.menu.noSocial") : L("app.menu.social", social.map(\.name).joined(separator: ", ")),
                      systemImage: "person.2")
                    .lineLimit(2)
                if !model.catalog.blockedDomains.isEmpty {
                    Label(L("app.menu.customDomains", model.catalog.blockedDomains.count), systemImage: "hand.raised")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// « 4:12 » ou « 1:04:12 ».
func remainingLabel(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.up)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Désactivation temporaire, comme sur Pi-hole : le filtrage reprend tout seul.
struct PauseMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(Catalog.pauseChoices, id: \.self) { s in
                Button(L("app.pause.\(Int(s))")) { model.pause(for: s) }
            }
        } label: {
            MenuLabel(title: L("app.pause.menu"), symbol: "timer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 6)
    }
}

struct MenuRow: View {
    var title: String
    var symbol: String
    var busy = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                MenuLabel(title: title, symbol: symbol)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MenuRowStyle())
    }
}

/// Bouton pleine largeur, surligné au survol, comme un élément de menu.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @StateObject private var hover = HoverState()

        var body: some View {
            configuration.label
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(hover.on && isEnabled ? Color.accentColor.opacity(configuration.isPressed ? 0.35 : 0.18) : .clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hover.on = $0 }
        }
    }
}

final class HoverState: ObservableObject { @Published var on = false }

struct StatusHeader: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: model.isProtected ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(model.isProtected ? .green : .orange)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(model.isProtected ? L("app.status.protected") : L("app.status.notProtected")).font(.headline)
                    if let date = model.status.lastApplied {
                        Text(L("app.status.lastUpdate", formatDate(date, date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.installer == nil {
                Problem(text: L("app.problem.noPrivoxy"))
            } else {
                if !model.privoxyRunning { Problem(text: L("app.problem.notRunning")) }
                if !model.systemProxyOK {
                    HStack {
                        Problem(text: L("app.problem.noProxy"))
                        Button(L("app.proxy.configure")) { model.configureSystemProxy(true) }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct Problem: View {
    var text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CategoryToggle: View {
    @EnvironmentObject var model: AppModel
    var category: Catalog.Category
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle(isOn: Binding(get: { category.enabled }, set: { model.setEnabled(category.id, $0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(category.listName)
                        if category.warning != nil {
                            Image(systemName: "tortoise.fill").foregroundStyle(.orange).help(category.displayWarning ?? "")
                        }
                        if model.status.failures[category.id] != nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                .help(model.status.failures[category.id] ?? "")
                        }
                    }
                    if category.enabled, let step = model.listProgress[category.id] {
                        ListProgressLine(step: step, file: model.confDir?.appendingPathComponent(PrivoxyActions.fileName(forCategory: category.id)))
                    } else if let n = model.status.domainCounts[category.id], category.enabled {
                        if compact {
                            Text(L("app.lists.domains", formatCount(n))).font(.caption2).foregroundStyle(.secondary)
                        } else {
                            ListStatusLine(count: n, list: model.status.lists[category.id],
                                           file: model.confDir?.appendingPathComponent(PrivoxyActions.fileName(forCategory: category.id)))
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if !compact {
                if category.custom != true, Catalog.hasLevels(category.id) {
                    Picker("", selection: Binding(get: { category.level ?? .light }, set: { model.setLevel(category.id, $0) })) {
                        ForEach(ListLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize().controlSize(.small)
                    .help(L("level.help"))
                }
                ListInfoButton(category: category)
                if category.custom == true {
                    Button(role: .destructive) { model.remove(category.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help(L("app.lists.remove"))
                }
            }
        }
    }
}

/// Bouton ⓘ : fiche de la liste dans une bulle.
struct ListInfoButton: View {
    @EnvironmentObject var model: AppModel
    var category: Catalog.Category
    @StateObject private var ui = Flag()

    var body: some View {
        Button { ui.on.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless).help(L("info.button"))
            .popover(isPresented: $ui.on, arrowEdge: .trailing) { ListInfoView(category: category).environmentObject(model) }
    }
}

/// Fiche d'une liste : description, auteur, taille, rythme de mise à jour, risque de blocage par erreur, licence.
struct ListInfoView: View {
    @EnvironmentObject var model: AppModel
    var category: Catalog.Category

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.listName).font(.headline)
                if let g = category.group { Text(g.title).font(.caption).foregroundStyle(.secondary) }
            }
            let info = category.info
            Text(info?.description ?? L("info.custom")).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                if let info {
                    GridRow {
                        label("info.maintainer")
                        if let url = URL(string: info.homepage) { Link(info.maintainer, destination: url) } else { Text(info.maintainer) }
                    }
                }
                if let size = sizeText(info) { GridRow { label("info.size"); Text(verbatim: size) } }
                if let info {
                    GridRow { label("info.updates"); Text(info.updates.text).foregroundStyle(isStale(info) ? Color.orange : Color.primary) }
                    GridRow { label("info.risk"); Text(info.risk.text).foregroundStyle(info.risk == .high ? Color.orange : Color.primary) }
                }
                if let lic = category.sources.compactMap(\.license).first, !category.sources[0].url.hasPrefix("file://") {
                    GridRow { label("info.license"); Text(verbatim: lic) }
                }
            }
            .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(category.sources.count > 1 ? "info.sources" : "info.source")).font(.caption).foregroundStyle(.secondary)
                ForEach(category.sources, id: \.url) { src in
                    Text(verbatim: src.url.hasPrefix("file://") ? L("app.lists.localFile", src.license ?? "") : src.url)
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func label(_ key: String) -> some View {
        Text(L(key)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func isStale(_ info: ListInfo) -> Bool {
        if case .stale = info.updates { return true }
        return false
    }

    /// Taille réelle si la liste est installée, sinon taille approximative.
    private func sizeText(_ info: ListInfo?) -> String? {
        if category.enabled, let n = model.status.domainCounts[category.id] { return L("app.lists.domains", formatCount(n)) }
        return info?.approxDomains.map { L("info.approx", formatCount($0)) }
    }
}

/// Étape en cours pendant la mise à jour : téléchargement (pourcentage ou taille), conversion, remplacement.
struct ListProgressLine: View {
    var step: ListProgress
    var file: URL?

    var body: some View {
        HStack(spacing: 5) {
            ProgressView().controlSize(.mini)
            Text(verbatim: text)
        }
        .font(.caption2).foregroundStyle(.secondary)
        .help(file.map { L("lists.file", $0.path) } ?? "")
    }

    private var text: String {
        switch step {
        case .downloading(let received, let expected):
            let loc = Locale(identifier: Localization.currentLanguage)
            if expected > 0 {
                let f = min(1, Double(received) / Double(expected))
                return L("lists.progress.download", f.formatted(.percent.precision(.fractionLength(0)).locale(loc)))
            }
            return L("lists.progress.download", received > 0 ? ByteCountFormatter.string(fromByteCount: received, countStyle: .file) : "")
        case .converting: return L("lists.progress.convert")
        case .installing: return L("lists.progress.install")
        }
    }
}

/// « 87 389 domaines · mise à jour le … (+312) », ou en orange si le téléchargement a échoué.
struct ListStatusLine: View {
    var count: Int
    var list: ListStatus?
    var file: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: summary).foregroundStyle(.secondary)
                .help(list?.changed.map { L("lists.lastChange", Self.short($0)) } ?? "")
            if let used = list?.cacheUsed {
                Text(verbatim: used.timeIntervalSince1970 > 0 ? L("lists.cacheUsed", Self.short(used))
                                                             : L("lists.cacheUsedNoDate"))
                    .foregroundStyle(.orange)
                    .help(list?.error ?? "")
            }
        }
        .font(.caption2)
        .help(file.map { L("lists.file", $0.path) } ?? "")
    }

    /// « 23 nov. à 7:30 » (l'année seulement si ce n'est pas l'année en cours).
    static func short(_ d: Date) -> String {
        let loc = Locale(identifier: Localization.currentLanguage)
        let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
        let style = sameYear ? Date.FormatStyle().day().month(.abbreviated).hour().minute()
                             : Date.FormatStyle().day().month(.abbreviated).year().hour().minute()
        return d.formatted(style.locale(loc))
    }

    private var summary: String {
        var parts = [L("app.lists.domains", formatCount(count))]
        guard let list else { return parts[0] }
        // Une seule date : la dernière mise à jour réussie (le dernier changement du contenu s'affiche au survol).
        if let d = list.checked {
            var s = L("lists.updated", Self.short(d))
            if list.changedNow, let delta = list.delta, delta != 0 { s += " (\(delta > 0 ? "+" : "−")\(formatCount(abs(delta))))" }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
    }
}

struct AddListMenu: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = AddListUI()

    var body: some View {
        Menu {
            Menu(L("app.add.themes")) { items(Catalog.themeLibrary) }
            Menu(L("app.add.others")) { items(Catalog.otherLibrary) }
            Divider()
            Button(L("app.add.url")) { ui.showURL = true }
            Button(L("app.add.file")) { model.addFromFile() }
        } label: {
            Label(L("app.add.title"), systemImage: "plus")
        }
        .fixedSize()
        .popover(isPresented: $ui.showURL) { AddURLForm(isPresented: $ui.showURL).environmentObject(model) }
    }

    /// Listes pas encore ajoutées.
    @ViewBuilder private func items(_ presets: [Catalog.Category]) -> some View {
        let missing = presets.filter { p in !model.catalog.categories.contains { $0.id == p.id } }
        if missing.isEmpty { Text(L("app.add.allAdded")) }
        ForEach(missing, id: \.id) { lib in Button(lib.name) { model.addFromLibrary(lib) } }
    }
}

struct AddURLForm: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @StateObject private var form = URLForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("app.add.url")).font(.headline)
            TextField(L("app.add.name"), text: $form.name)
            TextField(L("app.add.urlField"), text: $form.url)
            Text(L("app.add.formats")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("app.cancel")) { isPresented = false }
                Button(L("app.add")) { if model.addFromURL(name: form.name, url: form.url) { isPresented = false } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.isEmpty || form.url.count < 12)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

// `@State` est une macro dans ce SDK (plugin fourni seulement avec Xcode) :
// l'état local des vues passe par de petits ObservableObject.
final class AddListUI: ObservableObject { @Published var showURL = false }
final class Flag: ObservableObject { @Published var on = false }
final class URLForm: ObservableObject {
    @Published var name = ""
    @Published var url = "https://"
}
final class TextEntry: ObservableObject { @Published var text = "" }

/// Interrupteur qui garde sa couleur même quand la fenêtre n'est pas au premier plan
/// (le style système devient gris, ce qui laissait croire que le filtrage était coupé).
struct StateSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SwitchBody(configuration: configuration) }

    private struct SwitchBody: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let on = configuration.isOn
            HStack(spacing: 8) {
                configuration.label
                Spacer()
                Text(on ? L("app.menu.on") : L("app.menu.off"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(on ? Color.green : Color.orange)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Color.green : Color.secondary.opacity(0.35)).frame(width: 40, height: 22)
                    Circle().fill(.white).shadow(radius: 1).frame(width: 18, height: 18).padding(2)
                }
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { withAnimation(.easeInOut(duration: 0.15)) { configuration.isOn.toggle() } } }
                .accessibilityAddTraits(.isButton)
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// Référence vers la fenêtre AppKit qui contient une vue SwiftUI.
final class WindowRef: ObservableObject {
    weak var window: NSWindow?
    func close() { window?.close() }
}

struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { ref.window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if ref.window == nil { DispatchQueue.main.async { ref.window = v.window } }
    }
}

/// « Envoyer un avis » : par e-mail et/ou sur GitHub, selon ce qui est configuré.
struct FeedbackRow: View {
    @EnvironmentObject var model: AppModel
    let panel: WindowRef

    var body: some View {
        MenuRow(title: L("app.feedback"), symbol: "envelope") {
            if model.feedbackEmail != nil, model.issuesURL != nil {
                // Deux choix : petit menu à l'endroit du clic.
                let menu = NSMenu()
                let mail = FeedbackChoice(title: L("app.feedback.email")) { panel.close(); model.sendFeedbackByEmail() }
                let gh = FeedbackChoice(title: L("app.feedback.github")) { panel.close(); model.sendFeedbackOnGitHub() }
                // Secours si aucune messagerie n'est réglée (liens mailto: envoyés à un navigateur, par exemple).
                let copy = FeedbackChoice(title: L("app.feedback.copy")) { model.copyFeedbackEmail() }
                menu.addItem(mail.item); menu.addItem(gh.item); menu.addItem(.separator()); menu.addItem(copy.item)
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } else {
                panel.close()
                if model.feedbackEmail != nil { model.sendFeedbackByEmail() } else { model.sendFeedbackOnGitHub() }
            }
        }
    }
}

/// Élément de menu AppKit qui exécute une action Swift.
final class FeedbackChoice: NSObject {
    let item: NSMenuItem
    private let action: () -> Void
    init(title: String, action: @escaping () -> Void) {
        self.action = action
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.target = self
        item.action = #selector(run)
        item.representedObject = self   // garde l'objet en vie pendant l'affichage du menu
    }
    @objc private func run() { action() }
}

/// Icône de largeur fixe + texte : toutes les lignes du menu restent alignées.
struct MenuLabel: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 20, alignment: .center)
            Text(title)
        }
    }
}

/// Interrupteur des réglages : couleur d'accentuation conservée même quand la fenêtre n'est pas active
/// (l'interrupteur système devient gris, ce qui laisse croire qu'il est désactivé).
struct ColorSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { SwitchRow(configuration: configuration) }

    private struct SwitchRow: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let on = configuration.isOn
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.28)).frame(width: 34, height: 20)
                    Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).frame(width: 17, height: 17).padding(1.5)
                }
                .contentShape(Capsule())
                .onTapGesture { if isEnabled { withAnimation(.easeInOut(duration: 0.15)) { configuration.isOn.toggle() } } }
                .accessibilityAddTraits(.isButton)
                .opacity(isEnabled ? 1 : 0.45)
            }
        }
    }
}
