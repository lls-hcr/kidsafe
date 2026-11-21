import AppKit
import Foundation
import KidSafeCore

/// Moniteur : mini-fenêtre de statistiques et page détaillée. Rien ne tourne quand la fenêtre est fermée.
extension AppModel {

    func openMonitor() {
        // Le journal des sites bloqués alimente « dernier blocage » et la page détaillée.
        if !catalog.recordsBlocks,
           confirm(title: L("mon.enableLog.title"), message: L("mon.enableLog.message"), ok: L("mon.enableLog.ok"), style: .informational) {
            setLogBlocked(true)
        }
        openMonitorHandler?()
        refreshMonitor()
    }

    var domainsOnListsNow: Int { Monitor.domainsOnLists(status: status, catalog: catalog, at: now) }

    /// Appelé toutes les 5 s tant que la fenêtre du moniteur est ouverte.
    func refreshMonitor() {
        guard let e = endpoint else { return }
        let file = blockLogFile
        Task {
            let counters = await Monitor.counters(host: e.host, port: e.port)
            let last = file.flatMap { BlockLog.recent($0, limit: 1).first }
            self.monitorCounters = counters
            self.monitorLastBlock = last
        }
    }

    /// Guide d'utilisation (page locale, dans la langue de l'app).
    func openGuide() {
        let out = engine.paths.supportDir.appendingPathComponent("guide.html")
        guard let html = UserGuide.html(version: versionLabel),
              (try? FileManager.default.createDirectory(at: engine.paths.supportDir, withIntermediateDirectories: true)) != nil,
              (try? html.write(to: out, atomically: true, encoding: .utf8)) != nil else {
            if let url = URL(string: "https://github.com/lls-hcr/kidsafe#readme") { NSWorkspace.shared.open(url) }
            return
        }
        NSWorkspace.shared.open(out)
    }

    /// Génère la page détaillée (fichier HTML autonome) et l'ouvre dans le navigateur.
    /// `open` : ouvre la page dans le navigateur. Faux pour le bouton « Actualiser » de la page :
    /// le fichier est réécrit sur place et la page se recharge elle-même.
    func openDashboard(open: Bool = true) {
        guard !monitorBusy, let e = endpoint else { return }
        monitorBusy = true
        let file = blockLogFile, dir = confDir, domains = domainsOnListsNow, logOn = catalog.recordsBlocks
        let out = engine.paths.supportDir.appendingPathComponent("dashboard.html"), version = appVersion
        Task.detached {
            let counters = await Monitor.counters(host: e.host, port: e.port)
            let entries = file.map(BlockLog.all) ?? []
            let index = dir.map { Monitor.CategoryIndex(confDir: $0) }
            let html = Dashboard.html(.init(counters: counters, domainsOnLists: domains,
                                            summary: Monitor.summarize(entries, index: index),
                                            logEnabled: logOn, version: version))
            let ok = (try? html.write(to: out, atomically: true, encoding: .utf8)) != nil
            await MainActor.run {
                self.monitorBusy = false
                if !ok { self.lastError = L("mon.error") } else if open { NSWorkspace.shared.open(out) }
            }
        }
    }
}
