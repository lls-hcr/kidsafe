import KidSafeCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isLocked { LockBanner() }
            TabView {
                ListsTab().tabItem { Label(L("app.tab.lists"), systemImage: "list.bullet.rectangle") }
                SocialTab().tabItem { Label(L("app.tab.social"), systemImage: "person.2") }
                DomainsTab().tabItem { Label(L("app.tab.domains"), systemImage: "globe") }
                GeneralTab().tabItem { Label(L("app.tab.general"), systemImage: "gearshape") }
            }
            .padding()
            MenuBarHint()
        }
        .frame(width: 640, height: 590)
        .navigationTitle(L("app.settings"))
        .id(model.language)   // tout se redessine dans la nouvelle langue
    }
}

/// Rappelle où se trouve KidSafe : l'app vit dans la barre de menus.
struct MenuBarHint: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isProtected ? "checkmark.shield.fill" : "exclamationmark.shield")
            Text(model.isProtected ? L("app.status.protected") : L("app.status.notProtected")).fontWeight(.semibold)
            Text("·")
            Text(L("app.hint.menuBar"))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
}

struct LockBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack {
            Image(systemName: "lock.fill")
            Text(L("app.lock.banner")).font(.callout)
            Spacer()
            Button(L("app.lock.unlock")) { _ = model.requireUnlock() }
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}

// MARK: - Listes

struct ListsTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("app.lists.help")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                Section(L("app.lists.builtin")) {
                    ForEach(model.catalog.categories.filter { $0.custom != true }, id: \.id) { CategoryToggle(category: $0, compact: false) }
                }
                let custom = model.catalog.categories.filter { $0.custom == true }
                Section(L("app.lists.custom")) {
                    if custom.isEmpty { Text(L("app.lists.noCustom")).foregroundStyle(.secondary) }
                    ForEach(custom, id: \.id) { CategoryToggle(category: $0, compact: false) }
                }
            }
            .disabled(model.catalog.strictMode)
            HStack {
                AddListMenu()
                Spacer()
                if model.isApplying { ProgressView().controlSize(.small) }
                Button(L("app.updateNow")) { model.refreshListsManually() }
                    .disabled(model.isApplying || model.installer == nil || !model.catalog.filteringEnabled)
            }
            ErrorLine()
        }
    }
}

struct ErrorLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let err = model.lastError {
            Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

// MARK: - Réseaux sociaux

struct SocialTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("app.social.help")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(SocialService.all) { ServiceRow(service: $0) }
            Text(L("app.social.note")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ErrorLine()
        }
    }
}

struct ServiceRow: View {
    @EnvironmentObject var model: AppModel
    var service: SocialService

    var body: some View {
        let policy = model.catalog.policy(for: service.id)
        let blockedNow = policy.isBlocked(at: model.now)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: service.symbol).frame(width: 20)
                Text(service.name).font(.body.weight(.medium))
                if policy.mode != .allowed {
                    Text(blockedNow ? L("app.social.blockedNow") : L("app.social.allowedNow"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(blockedNow ? Color.red.opacity(0.18) : Color.green.opacity(0.18)))
                }
                Spacer()
                Picker("", selection: Binding(get: { policy.mode }, set: { model.setServiceMode(service.id, $0) })) {
                    ForEach(ServicePolicy.Mode.allCases, id: \.self) { Text(L("app.social.mode." + $0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            if policy.mode == .blockedDuring || policy.mode == .allowedOnlyDuring {
                ForEach(Array(policy.windows.enumerated()), id: \.offset) { index, window in
                    WindowEditor(window: window,
                                 onChange: { new in model.updateWindows(service.id) { if index < $0.count { $0[index] = new } } },
                                 onRemove: { model.updateWindows(service.id) { if index < $0.count { $0.remove(at: index) } } })
                }
                Button {
                    model.updateWindows(service.id) { $0.append(ServicePolicy.defaultWindow(for: policy.mode)) }
                } label: { Label(L("app.social.addWindow"), systemImage: "plus") }
                .buttonStyle(.borderless).font(.caption)
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Une plage : jours de la semaine + heure de début et de fin.
struct WindowEditor: View {
    var window: TimeWindow
    var onChange: (TimeWindow) -> Void
    var onRemove: () -> Void

    /// Initiales des jours, lundi d'abord, dans la langue de l'app.
    private var dayLetters: [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: Localization.currentLanguage)
        let s = cal.veryShortStandaloneWeekdaySymbols   // dimanche d'abord
        return Array(s[1...]) + [s[0]]
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(1...7, id: \.self) { day in
                    let on = window.days.contains(day)
                    Button(dayLetters[day - 1]) {
                        var w = window
                        if on { w.days.removeAll { $0 == day } } else { w.days.append(day); w.days.sort() }
                        onChange(w)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .foregroundStyle(on ? .white : .primary)
                    .font(.caption.weight(.semibold))
                }
            }
            Text(L("app.social.from"))
            TimeField(minutes: window.start) { var w = window; w.start = $0; onChange(w) }
            Text(L("app.social.to"))
            TimeField(minutes: window.end) { var w = window; w.end = $0; onChange(w) }
            if window.end <= window.start, window.end != window.start {
                Text(L("app.social.nextDay")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
        }
        .padding(.leading, 28)
        .font(.callout)
    }
}

struct TimeField: View {
    var minutes: Int
    var onChange: (Int) -> Void

    var body: some View {
        DatePicker("", selection: Binding(get: { date(minutes) }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            onChange((c.hour ?? 0) * 60 + (c.minute ?? 0))
        }), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.stepperField)
        .frame(width: 80)
    }

    private func date(_ m: Int) -> Date {
        Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - Domaines

struct DomainsTab: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var blockEntry = TextEntry()
    @StateObject private var allowEntry = TextEntry()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                DomainColumn(title: L("app.domains.blocked"), help: L("app.domains.blockedHelp"), symbol: "hand.raised.fill",
                             tint: .red, entry: blockEntry, domains: model.catalog.blockedDomains,
                             add: model.addBlocked, remove: model.removeBlocked)
                DomainColumn(title: L("app.tab.allow"), help: L("app.allow.help"), symbol: "checkmark.seal.fill",
                             tint: .green, entry: allowEntry, domains: model.catalog.allowlist,
                             add: model.addAllowed, remove: model.removeAllowed)
            }
            ErrorLine()
        }
    }
}

struct DomainColumn: View {
    var title: String
    var help: String
    var symbol: String
    var tint: Color
    @ObservedObject var entry: TextEntry
    var domains: [String]
    var add: (String) -> Bool
    var remove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
            Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L("app.allow.placeholder"), text: $entry.text).onSubmit(submit)
                Button(L("app.add"), action: submit).disabled(entry.text.isEmpty)
            }
            List {
                if domains.isEmpty { Text(L("app.domains.empty")).foregroundStyle(.secondary) }
                ForEach(domains, id: \.self) { d in
                    HStack {
                        Text(d)
                        Spacer()
                        Button { remove(d) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        if add(entry.text) { entry.text = "" }
    }
}

// MARK: - Général

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section(L("app.general.protection")) {
                Toggle(L("app.menu.filtering"), isOn: Binding(get: { model.catalog.filteringEnabled }, set: { model.setFiltering($0) }))
                Toggle(L("app.general.strict"), isOn: Binding(get: { model.catalog.strictMode }, set: { model.setStrictMode($0) }))
                Text(L("app.general.strictHelp")).font(.caption).foregroundStyle(.secondary)
                Toggle(L("app.login.toggle"), isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Text(L("app.login.help")).font(.caption).foregroundStyle(.secondary)
                if model.loginItemStatus == .requiresApproval {
                    Problem(text: L("app.login.approvalMessage"))
                }
                Picker(L("app.general.refresh"), selection: Binding(get: { model.catalog.refreshHours }, set: { model.setRefreshHours($0) })) {
                    ForEach(Catalog.refreshChoices, id: \.self) { Text(L("app.refresh.\($0)")).tag($0) }
                }
                if let date = model.status.lastApplied {
                    LabeledContent(L("app.general.lastUpdate")) { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
            Section(L("app.password.section")) {
                Text(L("app.password.help")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.hasPassword ? L("app.password.change") : L("app.password.set")) { model.setPassword() }
                    if model.hasPassword { Button(L("app.password.remove")) { model.removePassword() } }
                }
            }
            Section(L("app.general.proxy")) {
                LabeledContent(L("app.general.privoxy")) {
                    Text(model.installer?.confDir.path ?? L("app.general.notFound")).textSelection(.enabled)
                }
                LabeledContent(L("app.general.address")) { Text(model.endpoint.map { "\($0.host):\($0.port)" } ?? "—") }
                LabeledContent(L("app.general.running")) { Text(model.privoxyRunning ? L("app.yes") : L("app.no")) }
                LabeledContent(L("app.general.systemProxy")) { Text(model.systemProxyOK ? L("app.yes") : L("app.no")) }
                HStack {
                    Button(L("app.proxy.configure")) { model.configureSystemProxy(true) }
                    Button(L("app.proxy.remove")) { model.configureSystemProxy(false) }
                    Button(L("app.general.check")) { model.refreshSystemStatus() }
                }
                .disabled(model.installer == nil)
            }
            Section(L("updates.section")) {
                LabeledContent(L("updates.current")) { Text(model.appVersion) }
                if model.canCheckUpdates {
                    Toggle(L("updates.auto"), isOn: $model.autoUpdateCheck)
                    Toggle(L("autoupdate.toggle"), isOn: $model.autoInstallUpdates)
                        .disabled(!model.autoUpdateCheck || !model.canAutoInstall)
                    if !model.canAutoInstall {
                        Text(L("autoupdate.cannot")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(L("updates.checkNow")) { model.checkForUpdates() }.disabled(model.isCheckingUpdates)
                        if model.isCheckingUpdates { ProgressView().controlSize(.small) }
                        Spacer()
                        if let d = model.lastUpdateCheck {
                            Text(L("updates.lastCheck", d.formatted(date: .abbreviated, time: .shortened)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.isInstallingUpdate {
                        HStack { ProgressView().controlSize(.small); Text(L("autoupdate.installing")) }
                    } else if let u = model.availableUpdate {
                        Button { model.offerUpdate(u) } label: { Label(L("updates.menuAvailable", u.version), systemImage: "sparkles") }
                    }
                }
            }
            Section(L("app.uninstall.section")) {
                Text(L("app.uninstall.help")).font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { model.uninstall() } label: { Label(L("app.uninstall.button"), systemImage: "trash") }
            }
            Section(L("app.general.language")) {
                Picker(L("app.general.language"), selection: $model.language) {
                    Text(L("app.general.langSystem")).tag(AppModel.Language.system)
                    Text("Français").tag(AppModel.Language.fr)
                    Text("English").tag(AppModel.Language.en)
                }
                .labelsHidden()
            }
            if model.donateURL != nil {
                Section(L("app.donate.section")) {
                    Text(L("app.donate.help")).font(.caption).foregroundStyle(.secondary)
                    Button { model.donate() } label: { Label(L("app.donate"), systemImage: "heart.fill") }
                }
            }
        }
        .formStyle(.grouped)
    }
}
