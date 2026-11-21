import KidSafeCore
import SwiftUI

/// Onglet Avancé : réservé aux parents avertis, chaque action demande le mot de passe parent.
struct AdvancedTab: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var portEntry = TextEntry()
    @StateObject private var bypassEntry = TextEntry()

    var body: some View {
        Form {
            Section {
                Label(L("adv.warning"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Privoxy : port, état, dossier, redémarrage, réinitialisation
            Section(L("adv.privoxy")) {
                LabeledContent(L("adv.port")) {
                    HStack {
                        TextField("", text: $portEntry.text).frame(width: 80).multilineTextAlignment(.trailing)
                            .onSubmit { model.changePort(portEntry.text) }
                        Button(L("adv.apply")) { model.changePort(portEntry.text) }
                            .disabled(portEntry.text == String(model.currentPort) || model.advancedBusy)
                        if model.advancedBusy { ProgressView().controlSize(.small) }
                    }
                }
                if let note = model.portNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text(L("adv.port.help")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("adv.status")) { model.openPrivoxyPage("show-status") }
                    Button(L("adv.folder")) { model.openConfigFolder() }
                    Button(L("adv.restart")) { model.restartPrivoxyNow() }
                    Spacer()
                    Button(L("adv.reset"), role: .destructive) { model.resetPrivoxyConfig() }
                        .disabled(!model.usesBundledPrivoxy)
                }
            }

            // Éditeur d'actions de Privoxy (http://p.p)
            Section(L("adv.editor")) {
                Toggle(L("adv.editor.toggle"), isOn: Binding(get: { model.editorActive }, set: { model.setEditor($0) }))
                if model.editorActive, let until = model.catalog.advanced.editorUntil {
                    HStack {
                        Text(L("adv.editor.until", formatDate(until, date: .omitted, time: .shortened)))
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button(L("adv.editor.open")) { model.openPrivoxyPage("show-status") }
                    }
                }
                Text(L("adv.editor.help")).font(.caption).foregroundStyle(.secondary)
            }

            // Règles personnelles de Privoxy
            Section(L("adv.userAction")) {
                Text(L("adv.userAction.help")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("adv.userAction.edit")) { model.editUserAction() }
                    if model.editingUserAction {
                        Button(L("adv.userAction.check")) { model.checkUserAction() }.keyboardShortcut(.defaultAction)
                    }
                }
            }

            // Journal des sites bloqués
            Section(L("adv.log")) {
                Toggle(L("adv.log.toggle"), isOn: Binding(get: { model.catalog.recordsBlocks }, set: { model.setLogBlocked($0) }))
                    .disabled(model.catalog.notifyBlocked)
                if model.catalog.notifyBlocked {
                    Text(L("adv.log.neededByNotifications")).font(.caption).foregroundStyle(.secondary)
                }
                if model.catalog.recordsBlocks {
                    HStack {
                        Button(L("adv.log.open")) { model.openBlockLog() }
                        Button(L("mon.menu") + "…") { model.openMonitor() }
                        Spacer()
                        Button(L("adv.log.clear")) { model.clearBlockLog() }
                    }
                }
                Text(L("adv.log.help")).font(.caption).foregroundStyle(.secondary)
            }

            // Domaines qui ne passent pas par le filtre
            Section(L("adv.bypass")) {
                Text(L("adv.bypass.help")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L("adv.bypass.placeholder"), text: $bypassEntry.text)
                        .onSubmit { if model.addBypass(bypassEntry.text) { bypassEntry.text = "" } }
                    Button(L("app.add")) { if model.addBypass(bypassEntry.text) { bypassEntry.text = "" } }
                        .disabled(bypassEntry.text.isEmpty)
                }
                ForEach(AdvancedSettings.systemBypass, id: \.self) { d in
                    HStack { Text(verbatim: d).foregroundStyle(.secondary); Spacer(); Text(L("adv.bypass.system")).font(.caption).foregroundStyle(.tertiary) }
                }
                ForEach(model.catalog.advanced.proxyBypass, id: \.self) { d in
                    HStack {
                        Text(verbatim: d)
                        Spacer()
                        Button { model.removeBypass(d) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }

            // Plus tard : filtrer d'autres appareils (iPad, téléphone) via ce Mac
            Section {
                Toggle(isOn: .constant(false)) {
                    HStack {
                        Text(L("adv.lan"))
                        Text(L("adv.soon")).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                }
                .disabled(true)
                Text(L("adv.lan.help")).font(.caption).foregroundStyle(.secondary)
            }

            ErrorLine()
        }
        .formStyle(.grouped)
        .toggleStyle(ColorSwitchStyle())
        .onAppear {
            portEntry.text = String(model.currentPort)
        }
        .onChange(of: model.currentPort) { _, p in portEntry.text = String(p) }
    }
}
