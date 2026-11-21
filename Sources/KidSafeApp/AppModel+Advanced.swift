import AppKit
import Foundation
import KidSafeCore

/// Onglet Avancé : port, éditeur de Privoxy, user.action, journal, exclusions, dépannage.
/// Toutes les actions passent par le mot de passe parent (requireUnlock / mutate).
extension AppModel {

    var confDir: URL? { installer?.confDir }
    var currentPort: Int { endpoint?.port ?? catalog.advanced.port ?? BundledPrivoxy.port }

    // MARK: - Port

    /// Au lancement : si le port est pris par un autre programme, KidSafe en choisit un libre.
    func ensureFreePort() {
        guard usesBundledPrivoxy, let installer, let e = endpoint else { return }
        guard SystemStatus.isListening(e),
              !(PrivoxyController.listenerCommand(port: e.port)?.contains(installer.configFile.path) ?? false),
              let free = BundledPrivoxy.freePort(preferred: e.port + 1) else { return }
        do {
            try BundledPrivoxy.setPort(free, configFile: installer.configFile)
            mutate(locked: false, apply: false) { $0.advanced.port = free }
            privoxy = nil
            portNote = L("adv.port.auto", e.port, free)
        } catch {
            lastError = "\(error)"
        }
    }

    /// Change le port : retire le proxy de l'ancien port, redémarre Privoxy, remet le proxy sur le nouveau.
    func changePort(_ raw: String) {
        guard let port = Int(raw.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(port) else {
            lastError = L("adv.port.invalid"); return
        }
        guard port != currentPort else { return }
        guard requireUnlock() else { return }
        guard !SystemStatus.isListening(.init(host: "127.0.0.1", port: port)) else {
            lastError = L("adv.port.busy", port); return
        }
        guard let installer, let old = endpoint else { return }
        let wanted = proxyWanted, oldPrivoxy = privoxy
        advancedBusy = true
        Task.detached {
            SystemStatus.setSystemProxy(old, enable: false, prompt: nil)
            oldPrivoxy?.stop()
            var err: String?
            do { try BundledPrivoxy.setPort(port, configFile: installer.configFile) } catch { err = "\(error)" }
            await MainActor.run {
                if err == nil { self.mutate(locked: false, apply: false) { $0.advanced.port = port } }
                self.privoxy = nil
                self.makeController()
            }
            let newPrivoxy = await MainActor.run { self.privoxy }
            let ok = newPrivoxy?.start() ?? false
            if ok, wanted { SystemStatus.setSystemProxy(.init(host: "127.0.0.1", port: port), enable: true, prompt: nil) }
            await MainActor.run {
                self.advancedBusy = false
                self.portNote = nil
                self.lastError = err ?? (ok ? nil : L("app.error.privoxyStart"))
                self.refreshSystemStatus()
            }
        }
    }

    // MARK: - Éditeur de Privoxy

    var editorActive: Bool { catalog.advanced.editorActive(at: now) }

    func setEditor(_ on: Bool) {
        guard requireUnlock() else { return }
        if on {
            guard confirm(title: L("adv.editor.confirmTitle"), message: L("adv.editor.confirmMessage"),
                          ok: L("adv.editor.enable"), style: .critical) else { objectWillChange.send(); return }
        }
        let until: Date? = on ? Date().addingTimeInterval(AdvancedSettings.editorDuration) : nil
        guard mutate(locked: false, apply: false, { $0.advanced.editorUntil = until }) else { return }
        applyPrivoxyOptions()
        if on { openPrivoxyPage("show-status") }
    }

    /// Ferme l'éditeur une fois le délai passé (appelé toutes les 30 s).
    func closeExpiredEditor() {
        guard let until = catalog.advanced.editorUntil, until <= now else { return }
        mutate(locked: false, apply: false) { $0.advanced.editorUntil = nil }
        applyPrivoxyOptions()
    }

    func applyPrivoxyOptions() {
        do { try installer?.updateOptions(PrivoxyConfigEditor.Options(catalog: catalog)) } catch { lastError = "\(error)" }
    }

    func openPrivoxyPage(_ page: String = "") {
        if let url = URL(string: "http://p.p/" + page) { NSWorkspace.shared.open(url) }
    }

    // MARK: - user.action

    private var userAction: URL? { confDir?.appendingPathComponent("user.action") }
    private var userActionBackup: URL? { confDir?.appendingPathComponent("user.action.kidsafe-backup") }

    /// Sauvegarde user.action puis l'ouvre dans TextEdit.
    func editUserAction() {
        guard requireUnlock(), let file = userAction, let backup = userActionBackup else { return }
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: file, to: backup)
        editingUserAction = true
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Vérifie la config après modification ; propose de revenir à la sauvegarde si Privoxy la refuse.
    func checkUserAction() {
        guard let installer else { return }
        do {
            try installer.testConfig()
            editingUserAction = false
            try? userActionBackup.map { try FileManager.default.removeItem(at: $0) }
            restartPrivoxy()
            notice(L("adv.userAction.ok"))
        } catch {
            if confirm(title: L("adv.userAction.badTitle"), message: "\(error)", ok: L("adv.userAction.restore"), style: .warning),
               let file = userAction, let backup = userActionBackup {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.moveItem(at: backup, to: file)
                editingUserAction = false
                restartPrivoxy()
            }
        }
    }

    // MARK: - Journal

    var blockLogFile: URL? { confDir.map(BlockLog.logFile(confDir:)) }

    func setLogBlocked(_ on: Bool) {
        guard mutate(apply: false, { $0.advanced.logBlocked = on }) else { return }
        applyPrivoxyOptions()
        reloadBlockLog()
    }

    func reloadBlockLog() {
        blockEntries = blockLogFile.map { BlockLog.recent($0) } ?? []
    }

    func clearBlockLog() {
        guard requireUnlock(), let f = blockLogFile else { return }
        BlockLog.clear(f)
        reloadBlockLog()
    }

    func openBlockLog() {
        guard let f = blockLogFile else { return }
        NSWorkspace.shared.open([f], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Exclusions du proxy

    func addBypass(_ raw: String) -> Bool {
        guard let d = AdvancedSettings.normalizeBypass(raw) else { lastError = L("app.allow.invalid", raw); return false }
        guard mutate(apply: false, { if !$0.advanced.proxyBypass.contains(d) { $0.advanced.proxyBypass.append(d); $0.advanced.proxyBypass.sort() } })
        else { return false }
        pushBypass()
        return true
    }

    func removeBypass(_ d: String) {
        guard mutate(apply: false, { $0.advanced.proxyBypass.removeAll { $0 == d } }) else { return }
        pushBypass()
    }

    /// Met à jour la liste d'exclusions du Mac si le filtre est actif.
    private func pushBypass() {
        SystemStatus.bypassDomains = catalog.advanced.bypassDomains
        guard systemProxyOK, let e = endpoint else { return }
        Task.detached { SystemStatus.setSystemProxy(e, enable: true, prompt: nil) }
    }

    // MARK: - Dépannage

    func openConfigFolder() {
        if let dir = confDir { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("config")]) }
    }

    func restartPrivoxyNow() {
        guard requireUnlock() else { return }
        restartPrivoxy()
    }

    /// Remet les fichiers de Privoxy (dont user.action) à leur état d'origine ; listes et réglages conservés.
    func resetPrivoxyConfig() {
        guard requireUnlock(), usesBundledPrivoxy else { return }
        guard confirm(title: L("adv.reset.title"), message: L("adv.reset.message"), ok: L("adv.reset.ok"), style: .warning) else { return }
        do {
            installer = try BundledPrivoxy.reset(supportDir: engine.paths.supportDir, port: currentPort) ?? installer
            applyPrivoxyOptions()
            restartPrivoxy()
            notice(L("adv.reset.done"))
        } catch {
            lastError = "\(error)"
        }
    }
}
