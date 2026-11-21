import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Pas de fenêtre au lancement : KidSafe vit dans la barre de menus.
        // Un double-clic sur l'app déjà ouverte affiche les réglages (applicationShouldHandleReopen).
        model.openSettingsHandler = { [weak self] in self?.showSettings() }
        model.startUp()
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

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.title = L("app.settings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
                MenuRow(title: L("app.menu.testPrivoxy"), symbol: "stethoscope") { panel.close(); model.openPrivoxyTestPage() }
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
            if !model.catalog.filteringEnabled {
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
                        Text(L("app.status.lastUpdate", date.formatted(date: .abbreviated, time: .shortened)))
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
                        Text(category.displayName)
                        if category.warning != nil {
                            Image(systemName: "tortoise.fill").foregroundStyle(.orange).help(category.displayWarning ?? "")
                        }
                        if model.status.failures[category.id] != nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                .help(model.status.failures[category.id] ?? "")
                        }
                    }
                    if let n = model.status.domainCounts[category.id], category.enabled {
                        Text(L("app.lists.domains", formatCount(n))).font(.caption2).foregroundStyle(.secondary)
                    }
                    if !compact, let src = category.sources.first {
                        Text(src.url.hasPrefix("file://") ? L("app.lists.localFile", src.license ?? "") : src.url)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if !compact, category.custom == true {
                Button(role: .destructive) { model.remove(category.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help(L("app.lists.remove"))
            }
        }
    }
}

struct AddListMenu: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = AddListUI()

    var body: some View {
        Menu {
            Menu(L("app.add.library")) {
                ForEach(Catalog.library.filter { lib in !model.catalog.categories.contains { $0.id == lib.id } }, id: \.id) { lib in
                    Button(lib.name) { model.addFromLibrary(lib) }
                }
            }
            Button(L("app.add.url")) { ui.showURL = true }
            Button(L("app.add.file")) { model.addFromFile() }
        } label: {
            Label(L("app.add.title"), systemImage: "plus")
        }
        .fixedSize()
        .popover(isPresented: $ui.showURL) { AddURLForm(isPresented: $ui.showURL).environmentObject(model) }
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
        if model.feedbackEmail != nil, model.issuesURL != nil {
            Menu {
                Button(L("app.feedback.email")) { panel.close(); model.sendFeedbackByEmail() }
                Button(L("app.feedback.github")) { panel.close(); model.sendFeedbackOnGitHub() }
            } label: {
                MenuLabel(title: L("app.feedback"), symbol: "envelope").frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.vertical, 4).padding(.horizontal, 6)
        } else {
            MenuRow(title: L("app.feedback"), symbol: "envelope") {
                panel.close()
                if model.feedbackEmail != nil { model.sendFeedbackByEmail() } else { model.sendFeedbackOnGitHub() }
            }
        }
    }
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
