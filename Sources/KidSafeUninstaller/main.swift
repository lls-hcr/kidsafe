import AppKit
import KidSafeCore

// « Désinstaller KidSafe » (fourni dans le .dmg) : remet le Mac dans son état d'origine,
// même si l'app KidSafe a déjà été supprimée ou ne s'ouvre plus.

/// `--yes` (tests, scripts) : pas de confirmation ni de message final. Le mot de passe parent reste exigé.
let assumeYes = CommandLine.arguments.contains("--yes")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

func show(_ title: String, _ message: String, buttons: [String], style: NSAlert.Style = .informational,
          field: NSTextField? = nil) -> NSApplication.ModalResponse {
    let a = NSAlert()
    a.alertStyle = style
    a.messageText = title
    a.informativeText = message
    buttons.forEach { a.addButton(withTitle: $0) }
    if let field { field.frame = NSRect(x: 0, y: 0, width: 260, height: 24); a.accessoryView = field; a.window.initialFirstResponder = field }
    app.activate(ignoringOtherApps: true)
    return a.runModal()
}

// 1. Confirmation.
guard assumeYes || show(L("app.uninstall.title"), L("uninstaller.message"), buttons: [L("app.uninstall.ok"), L("app.cancel")],
           style: .warning) == .alertFirstButtonReturn else { exit(0) }

// 2. Mot de passe parent, s'il y en a un : sans lui, un enfant pourrait tout désinstaller.
let paths = KidSafePaths.user
if let hash = (try? Catalog.load(from: paths.catalogFile))?.parentPassword {
    var ok = false
    for _ in 0..<3 {
        let field = NSSecureTextField(string: "")
        guard show(L("app.lock.title"), L("uninstaller.password"), buttons: [L("app.uninstall.ok"), L("app.cancel")],
                   field: field) == .alertFirstButtonReturn else { exit(0) }
        if hash.verify(field.stringValue) { ok = true; break }
        NSSound.beep()
    }
    guard ok else {
        _ = show(L("app.lock.title"), L("uninstaller.badPassword"), buttons: ["OK"], style: .critical)
        exit(1)
    }
}

// 3. Quitter KidSafe s'il tourne : il retire lui-même le proxy puis arrête Privoxy.
for running in NSRunningApplication.runningApplications(withBundleIdentifier: KidSafeUninstaller.bundleID) {
    running.terminate()
    let end = Date().addingTimeInterval(10)
    while !running.isTerminated && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
    if !running.isTerminated { running.forceTerminate() }
}

// 4. Nettoyage (proxy de KidSafe, Privoxy intégré, réglages).
// Port de KidSafe : celui de sa config (il a pu être changé dans l'onglet Avancé), et le port par défaut.
let bundledConfig = BundledPrivoxy.installDir(supportDir: paths.supportDir).appendingPathComponent("config")
var endpoints = [SystemStatus.Endpoint(host: "127.0.0.1", port: BundledPrivoxy.port)]
if FileManager.default.fileExists(atPath: bundledConfig.path) {
    let e = SystemStatus.listenAddress(configFile: bundledConfig)
    if !endpoints.contains(e) { endpoints.append(e) }
}
if let ext = PrivoxyInstaller.detectExternal() { endpoints.append(SystemStatus.listenAddress(configFile: ext.configFile)) }
if let err = KidSafeUninstaller.perform(paths: paths, endpoints: endpoints, adminPrompt: L("app.proxy.adminPromptOff")) {
    _ = show(L("app.uninstall.title"), L("app.uninstall.proxyFailed", err), buttons: ["OK"], style: .critical)
    exit(1)
}

// 5. KidSafe à la corbeille (sauf la copie du .dmg, en lecture seule).
var apps = Set(NSWorkspace.shared.urlsForApplications(withBundleIdentifier: KidSafeUninstaller.bundleID).map(\.standardizedFileURL))
for candidate in ["/Applications/KidSafe.app", NSHomeDirectory() + "/Applications/KidSafe.app", NSHomeDirectory() + "/Desktop/KidSafe.app"]
where FileManager.default.fileExists(atPath: candidate) {
    apps.insert(URL(fileURLWithPath: candidate).standardizedFileURL)
}
let toTrash = apps.filter { !$0.path.hasPrefix("/Volumes/") && !$0.path.contains("/.Trash/") }
if !toTrash.isEmpty {
    var done = false
    NSWorkspace.shared.recycle(Array(toTrash)) { _, _ in done = true }
    let end = Date().addingTimeInterval(10)
    while !done && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
}

if !assumeYes { _ = show(L("uninstaller.doneTitle"), L("uninstaller.done"), buttons: ["OK"]) }
print("KidSafe désinstallé. Mis à la corbeille : \(toTrash.map(\.path).joined(separator: ", "))")
exit(0)
