import AppKit
import Foundation
import KidSafeCore
import ServiceManagement
import UniformTypeIdentifiers

/// État de l'app et actions de l'interface. Toute écriture passe par KidSafeEngine.
@MainActor
final class AppModel: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case system, fr, en
        var id: String { rawValue }
    }

    @Published private(set) var catalog: Catalog
    @Published private(set) var status: KidSafeStatus
    @Published var installer: PrivoxyInstaller?
    @Published private(set) var privoxyRunning = false
    @Published private(set) var systemProxyOK = false
    @Published private(set) var isApplying = false
    /// Étape en cours de chaque liste pendant une mise à jour (vide le reste du temps).
    @Published private(set) var listProgress: [String: ListProgress] = [:]
    @Published var lastError: String?
    /// Heure courante, rafraîchie toutes les 30 s (état « bloqué maintenant » des réseaux sociaux).
    @Published private(set) var now = Date()
    /// État de l'ouverture automatique au démarrage de la session.
    @Published private(set) var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    /// Fin du déverrouillage par le mot de passe parent.
    @Published private(set) var unlockedUntil: Date?
    @Published var language: Language {
        didSet {
            AppModel.prefs.set(language.rawValue, forKey: "language")
            Localization.forcedLanguage = language == .system ? nil : language.rawValue
        }
    }

    let engine: KidSafeEngine
    /// Préférences de l'app. KIDSAFE_DEFAULTS_SUITE (tests) les isole de celles de l'utilisateur.
    nonisolated(unsafe) static let prefs: UserDefaults =
        ProcessInfo.processInfo.environment["KIDSAFE_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    /// Durée de déverrouillage après saisie du mot de passe parent.
    static let unlockDuration: TimeInterval = 5 * 60
    /// Lien de don, défini à la construction (clé `KidSafeDonateURL` de l'Info.plist).
    let donateURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "KidSafeDonateURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }

    /// Développement : KIDSAFE_SUPPORT_DIR et KIDSAFE_PRIVOXY_CONF isolent l'app de la vraie configuration.
    private static let env = ProcessInfo.processInfo.environment
    private var pendingApply: Task<Void, Never>?
    /// Un changement du parent attend d'être appliqué : après l'application, Privoxy est
    /// redémarré pour couper les connexions déjà ouvertes vers les sites désormais bloqués.
    private var reconnectAfterApply = false
    // Moniteur (voir AppModel+Monitor.swift) : rafraîchi seulement quand sa fenêtre est ouverte.
    @Published var monitorCounters: Monitor.Counters?
    @Published var monitorLastBlock: BlockLog.Entry?
    @Published var monitorBusy = false
    @Published var monitorPinned: Bool = AppModel.prefs.object(forKey: "monitorPinned") as? Bool ?? true {
        didSet { AppModel.prefs.set(monitorPinned, forKey: "monitorPinned"); monitorPinHandler?(monitorPinned) }
    }
    var openMonitorHandler: (() -> Void)?
    var monitorPinHandler: ((Bool) -> Void)?

    // État de l'onglet Avancé (voir AppModel+Advanced.swift).
    @Published var blockEntries: [BlockLog.Entry] = []
    @Published var portNote: String?
    @Published var editingUserAction = false
    @Published var advancedBusy = false

    /// Privoxy, démarré par l'app au lancement et arrêté quand elle quitte.
    var privoxy: PrivoxyController?
    private var healthTimer: Timer?
    var healthBusy = false
    private var lastAutoProxyFailure: Date?
    private var safetyNoticeShown = false
    private var uninstalling = false
    /// « Quitter » choisi dans le menu (mot de passe saisi) : seul cas où le proxy est retiré
    /// quand le parent a choisi de couper internet sans KidSafe.
    private var quitByParent = false
    private var privoxyDownNoticeShown = false
    /// Proposition de protection à montrer au prochain passage de la minuterie (pas au milieu d'une action).
    private var protectionOfferPending = false
    /// Règle « proxy du système » verrouillée dans Firefox (voir FirefoxPolicy).
    @Published private(set) var firefoxLocked = FirefoxPolicy.isInstalled
    @Published private(set) var firefoxBusy = false
    /// Événements récents (arrêts inattendus…), affichés dans le moniteur.
    @Published private(set) var recentEvents: [EventLog.Event] = []
    /// Le parent a branché le Mac sur Privoxy : KidSafe remet le proxy à chaque lancement
    /// et le retire toujours en quittant, avant d'arrêter Privoxy.
    var proxyWanted: Bool {
        get { AppModel.prefs.bool(forKey: "proxyWanted") }
        set { AppModel.prefs.set(newValue, forKey: "proxyWanted") }
    }
    /// Réseaux sociaux bloqués lors de la dernière vérification des plages horaires.
    private var lastBlockedServiceIDs: Set<String> = []
    private var timer: Timer?
    private var resumeTimer: Timer?
    /// Message « site bloqué » (voir BlockSplash.swift).
    var blockNotifier: BlockNotifier?
    var notifyTimer: Timer?

    /// Vrai quand KidSafe utilise le Privoxy intégré à l'app (cas normal pour l'utilisateur).
    private(set) var usesBundledPrivoxy = false

    /// Privoxy intégré à l'app (installé dans le dossier de KidSafe au premier lancement) ;
    /// à défaut (développement), un Privoxy existant comme celui de Homebrew.
    private func detectInstaller() -> PrivoxyInstaller? {
        if let dir = Self.env["KIDSAFE_PRIVOXY_CONF"] {
            return PrivoxyInstaller(confDir: URL(fileURLWithPath: dir),
                                    privoxyBinary: BundledPrivoxy.binary(in: .main) ?? PrivoxyInstaller.detectExternal()?.privoxyBinary)
        }
        if BundledPrivoxy.binary(in: .main) != nil {
            do {
                if let inst = try BundledPrivoxy.prepare(supportDir: engine.paths.supportDir,
                                                         port: catalog.advanced.port ?? BundledPrivoxy.port) {
                    usesBundledPrivoxy = true
                    return inst
                }
            } catch {
                lastError = L("app.error.privoxyStart") + " (\(error.localizedDescription))"
            }
        }
        return PrivoxyInstaller.detectExternal()
    }

    init() {
        let saved = Language(rawValue: AppModel.prefs.string(forKey: "language") ?? "") ?? .system
        Localization.forcedLanguage = saved == .system ? nil : saved.rawValue
        language = saved
        // Premier lancement sous le nom Yamoxy : une ancienne copie encore ouverte (KidSafe.app) est quittée
        // (elle retire son proxy), puis le dossier de KidSafe est déplacé (en cas d'échec, il reste utilisé).
        if Self.env["KIDSAFE_SUPPORT_DIR"] == nil, Self.env["KIDSAFE_SCREENSHOTS"] == nil {
            Self.quitOtherCopies()
            if case .failed(let why) = KidSafePaths.migrateLegacy() { NSLog("Yamoxy : dossier de KidSafe non déplacé (%@)", why) }
        }
        engine = KidSafeEngine(paths: Self.env["KIDSAFE_SUPPORT_DIR"].map { KidSafePaths(supportDir: URL(fileURLWithPath: $0)) } ?? .user)
        catalog = (try? engine.loadCatalog()) ?? .default
        status = engine.loadStatus()
        SystemStatus.bypassDomains = catalog.advanced.bypassDomains
        // Mode capture d'écran (KIDSAFE_SCREENSHOTS) : aucune minuterie, aucun Privoxy, aucun réglage modifié.
        guard Self.env["KIDSAFE_SCREENSHOTS"] == nil else { return }
        installer = detectInstaller()
        refreshSystemStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        scheduleResume()
    }

    /// Données de démonstration pour les captures d'écran du guide (rien n'est enregistré).
    func loadDemoState() {
        var c = Catalog.default
        for id in ["adult", "bypass", "security"] { if let i = c.categories.firstIndex(where: { $0.id == id }) { c.categories[i].enabled = true } }
        try? c.setLevel("security", .normal)
        if let g = Catalog.library.first(where: { $0.id == "gambling" }) { c.categories.append(g) }
        c.services["tiktok"] = ServicePolicy(mode: .blocked)
        c.services["youtube"] = ServicePolicy(mode: .blockedDuring, windows: [TimeWindow(days: TimeWindow.allDays, start: 21 * 60, end: 7 * 60)])
        c.services["instagram"] = ServicePolicy(mode: .allowedOnlyDuring, windows: [TimeWindow(days: [3, 6, 7], start: 14 * 60, end: 18 * 60)])
        c.blockedDomains = ["roblox.com", "fortnite.com"]
        c.allowlist = ["khanacademy.org", "wikipedia.org"]
        c.advanced.logBlocked = true
        c.advanced.proxyBypass = ["intranet.example"]
        catalog = c
        var s = KidSafeStatus()
        s.lastApplied = Calendar.current.date(bySettingHour: 7, minute: 30, second: 0, of: Date())
        s.domainCounts = ["adult": 81_546, "bypass": 24_014, "security": 345_250, "gambling": 95_194]
        let checked = s.lastApplied, day: TimeInterval = 86_400
        s.lists = ["adult": .init(checked: checked, changed: checked, changedNow: true, delta: 312),
                   "bypass": .init(checked: checked, changed: checked?.addingTimeInterval(-2 * day)),
                   "security": .init(checked: checked, changed: checked?.addingTimeInterval(-day)),
                   "gambling": .init(checked: checked, changed: checked?.addingTimeInterval(-5 * day))]
        status = s
        now = Calendar.current.date(bySettingHour: 15, minute: 10, second: 0, of: Date()) ?? Date()
        installer = PrivoxyInstaller(confDir: BundledPrivoxy.installDir(supportDir: KidSafePaths.user.supportDir))
        privoxyRunning = true
        systemProxyOK = true
        loginItemStatus = .enabled
        monitorCounters = .init(requests: 45_358, blocked: 8_543, since: Calendar.current.date(bySettingHour: 8, minute: 12, second: 0, of: Date()))
        monitorLastBlock = .init(date: Date().addingTimeInterval(-120), target: "www.tiktok.com:443", host: "www.tiktok.com")
    }

    /// Captures d'écran : mot de passe parent et protections activées (rien n'est enregistré).
    func loadDemoProtection() {
        catalog.parentPassword = PasswordHash.make("demo")
        catalog.blockWhenClosed = true
        firefoxLocked = true
        unlockedUntil = .distantFuture   // pas de bandeau « verrouillé » sur les captures
    }

    // MARK: - État

    var endpoint: SystemStatus.Endpoint? {
        installer.map { SystemStatus.listenAddress(configFile: $0.configFile) }
    }

    /// Protégé = filtrage actif, Privoxy répond, le proxy du Mac pointe dessus, et les listes sont installées.
    var isProtected: Bool {
        catalog.filteringEnabled && privoxyRunning && systemProxyOK && status.lastApplied != nil
    }

    var enabledCount: Int { catalog.categories.filter(\.enabled).count }
    var blockedServicesNow: [SocialService] { catalog.blockedServices(at: now) }

    var hasPassword: Bool { catalog.parentPassword != nil }
    var isLocked: Bool { hasPassword && (unlockedUntil.map { $0 <= now } ?? true) }

    func refreshSystemStatus() {
        makeController()
        guard let e = endpoint else { privoxyRunning = false; systemProxyOK = false; return }
        privoxyRunning = SystemStatus.isListening(e)
        systemProxyOK = SystemStatus.systemProxyPointsTo(e)
    }

    /// Toutes les 30 s : plages horaires des réseaux sociaux, verrouillage, mise à jour automatique des listes.
    private func tick() {
        now = Date()
        if catalog.pauseExpired(at: now) { resumeIfPauseExpired(); return }
        if let until = unlockedUntil, until <= now { unlockedUntil = nil }
        closeExpiredEditor()
        if let installer, !isApplying, status.lastApplied != nil {
            do {
                if try engine.refreshServices(catalog, installer: installer, date: now) {
                    // Un réseau vient d'être bloqué : on coupe ses connexions déjà ouvertes.
                    let ids = Set(blockedServicesNow.map(\.id))
                    if !ids.isSubset(of: lastBlockedServiceIDs) { restartPrivoxy() }
                    lastBlockedServiceIDs = ids
                }
            } catch { lastError = "\(error)" }
        }
        if heartbeatStarted { Heartbeat.beat(heartbeatFile, now: now) }
        if protectionOfferPending, NSApp.modalWindow == nil, !uninstalling {
            protectionOfferPending = false
            offerProtection()
        }
        if Int(now.timeIntervalSince1970) % 300 < 30 {
            refreshSystemStatus()
            noteLoginItemStatus(SMAppService.mainApp.status)
            firefoxLocked = FirefoxPolicy.isInstalled
        }
        if autoUpdateCheck, !isCheckingUpdates,
           lastUpdateCheck.map({ now.timeIntervalSince($0) > Self.updateCheckInterval }) ?? true {
            checkForUpdates(manual: false)
        }
        guard installer != nil, !isApplying, catalog.filteringEnabled else { return }
        if status.lastApplied == nil {
            applyNow()
        } else if catalog.refreshHours > 0, let last = status.lastApplied,
                  now.timeIntervalSince(last) > Double(catalog.refreshHours) * 3600 {
            applyNow()
        }
    }

    // MARK: - Mot de passe parent

    /// Demande le mot de passe parent s'il y en a un. Renvoie vrai si l'action peut continuer.
    func requireUnlock() -> Bool {
        guard isLocked, let hash = catalog.parentPassword else { return true }
        while true {
            let answer = askSecret(title: L("app.lock.title"), message: L("app.lock.message"), ok: L("app.lock.unlock"),
                                   extra: L("app.lock.forgot"))
            if answer.extra {
                if resetForgottenPassword() { return true }
                continue
            }
            guard let pw = answer.value else {
                objectWillChange.send()
                return false
            }
            if hash.verify(pw) {
                unlockedUntil = Date().addingTimeInterval(Self.unlockDuration)
                now = Date()
                // Parents qui avaient déjà un mot de passe : la proposition s'affiche une fois, après l'action en cours.
                if !Self.prefs.bool(forKey: "protectionOffered") { protectionOfferPending = true }
                return true
            }
            NSSound.beep()
        }
    }

    func lock() { unlockedUntil = nil }

    func setPassword() {
        guard requireUnlock() else { return }
        chooseNewPassword()
    }

    /// Saisie et confirmation du nouveau mot de passe (le droit de le changer a déjà été vérifié).
    @discardableResult
    private func chooseNewPassword() -> Bool {
        guard let pw = askSecret(title: L("app.password.newTitle"), message: L("app.password.newMessage"), ok: L("app.password.save")),
              !pw.isEmpty else { return false }
        guard let again = askSecret(title: L("app.password.confirmTitle"), message: "", ok: L("app.password.save")) else { return false }
        guard pw == again else { notice(L("app.password.mismatch")); return false }
        let hash = PasswordHash.make(pw)
        let first = !hasPassword
        mutate(locked: false, apply: false) { $0.parentPassword = hash }
        unlockedUntil = Date().addingTimeInterval(Self.unlockDuration)
        if first { offerProtection(force: true) }
        return true
    }

    /// « Mot de passe oublié ? » : le mot de passe d'un administrateur du Mac (fenêtre de macOS, jamais vue par KidSafe)
    /// permet de choisir un nouveau mot de passe parent ou de le supprimer. Un enfant avec un compte standard
    /// ne le connaît pas ; un enfant administrateur peut de toute façon tout défaire.
    /// Renvoie vrai si KidSafe est déverrouillé ensuite.
    private func resetForgottenPassword() -> Bool {
        if let err = AdminShell.run([["/usr/bin/true"]], prompt: L("app.lock.forgotPrompt")) {
            if !AdminShell.isCancel(err) { notice(L("app.lock.forgotFailed")) }
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("app.lock.resetTitle")
        a.informativeText = L("app.lock.resetMessage")
        a.addButton(withTitle: L("app.lock.resetNew"))
        a.addButton(withTitle: L("app.password.remove"))
        a.addButton(withTitle: L("app.cancel"))
        switch a.runModal() {
        case .alertFirstButtonReturn:
            return chooseNewPassword()
        case .alertSecondButtonReturn:
            removePasswordUnlocked()
            return true
        default:
            return false
        }
    }

    /// Proposée à la création du mot de passe parent (et une fois aux parents qui en avaient déjà un) :
    /// les protections contre les contournements les plus simples, cochées par défaut.
    func offerProtection(force: Bool = false) {
        guard hasPassword, force || !Self.prefs.bool(forKey: "protectionOffered") else { return }
        Self.prefs.set(true, forKey: "protectionOffered")
        let bypass = catalog.categories.first { $0.id == "bypass" }
        var choices: [(title: String, apply: () -> Void)] = []
        if let bypass, !bypass.enabled {
            choices.append((L("protect.offer.bypass"), { self.mutate(locked: false) { try $0.setEnabled(bypass.id, true) } }))
        }
        if !catalog.blockWhenClosed {
            choices.append((L("protect.offer.blockWhenClosed"), { self.setBlockWhenClosed(true, locked: false) }))
        }
        if firefoxInstalled, !firefoxLocked {
            choices.append((L("protect.offer.firefox"), { self.setFirefoxLock(true, locked: false) }))
        }
        guard !choices.isEmpty,
              let picked = checkboxAlert(title: L("protect.offer.title"), message: L("protect.offer.message"),
                                         choices: choices.map(\.title), ok: L("protect.offer.apply"), cancel: L("protect.offer.later"))
        else { return }
        for (on, choice) in zip(picked, choices) where on { choice.apply() }
    }

    // MARK: - Protection contre les contournements

    /// Couper internet quand KidSafe est fermé (seulement avec un mot de passe parent).
    func setBlockWhenClosed(_ on: Bool, locked: Bool = true) {
        mutate(locked: locked, apply: false) { $0.blockWhenClosed = on }
    }

    var firefoxInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: FirefoxPolicy.bundleID) != nil }

    /// Verrouille (ou libère) le proxy dans Firefox. macOS demande le mot de passe administrateur.
    func setFirefoxLock(_ on: Bool, locked: Bool = true) {
        if locked { guard requireUnlock() else { objectWillChange.send(); return } }
        guard !firefoxBusy else { return }
        firefoxBusy = true
        let prompt = on ? L("firefox.adminPrompt") : L("firefox.adminPromptOff")
        Task.detached {
            let err = on ? FirefoxPolicy.install(prompt: prompt) : FirefoxPolicy.remove(prompt: prompt)
            let state = FirefoxPolicy.isInstalled
            await MainActor.run {
                self.firefoxBusy = false
                self.firefoxLocked = state
                if let err, !AdminShell.isCancel(err) { self.lastError = L("firefox.error", err) }
                else if err == nil, on, state { self.notice(L("firefox.done")) }
            }
        }
    }

    // MARK: - Événements (moniteur)

    var heartbeatFile: URL { Heartbeat.file(supportDir: engine.paths.supportDir) }
    var eventsFile: URL { EventLog.file(supportDir: engine.paths.supportDir) }
    private var heartbeatStarted = false

    /// Au lancement : si le signe de vie de la session précédente est resté, KidSafe ne s'est pas arrêté normalement.
    private func startHeartbeat() {
        if let last = Heartbeat.lastBeat(heartbeatFile) {
            EventLog.append(.init(date: Date(), kind: .unexpectedStop, lastSeen: last), to: eventsFile)
        }
        Heartbeat.beat(heartbeatFile)
        heartbeatStarted = true
        trashLeftoverOldApp()
        reRegisterLoginItemIfMoved()
        noteLoginItemStatus(SMAppService.mainApp.status)
        loadEvents()
    }

    func loadEvents() { recentEvents = EventLog.recent(eventsFile) }

    /// Autre copie de l'app encore ouverte (ex. KidSafe.app à côté de Yamoxy.app, installée à la main) : quittée
    /// proprement, au plus 10 s d'attente. Deux copies se disputeraient Privoxy et le dossier de l'app.
    private static func quitOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = Bundle.main.bundleURL.standardizedFileURL
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where other.processIdentifier != getpid() && other.bundleURL?.standardizedFileURL != me {
            other.terminate()
            let end = Date().addingTimeInterval(10)
            while !other.isTerminated && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        }
    }

    /// Installation à la main (glissée depuis le .dmg) : l'ancienne KidSafe.app restée dans Applications part à la corbeille,
    /// seulement si c'est bien la même app (même identifiant) dans une version plus ancienne.
    private func trashLeftoverOldApp() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let here = Bundle.main.bundleURL
        let dirs = [here.deletingLastPathComponent(), URL(fileURLWithPath: "/Applications"),
                    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications")]
        let old = AppUpdater.leftoverOldApps(current: here, bundleID: id, version: appVersion, in: dirs)
        guard !old.isEmpty else { return }
        NSWorkspace.shared.recycle(old) { trashed, error in
            if let error { NSLog("Yamoxy : ancienne app non mise à la corbeille (%@)", error.localizedDescription) }
            else { NSLog("Yamoxy : mise à la corbeille : %@", trashed.values.map(\.path).joined(separator: ", ")) }
        }
    }

    /// L'app a changé de nom ou d'emplacement (KidSafe.app devenue Yamoxy.app) : macOS peut garder l'ouverture
    /// au démarrage sur l'ancien chemin. Si elle était activée, elle est réinscrite pour l'app actuelle.
    private func reRegisterLoginItemIfMoved() {
        let key = "loginItemAppPath", path = Bundle.main.bundlePath
        // Seulement l'app installée (pas une copie lancée depuis le .dmg ou un dossier de développement).
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              Self.prefs.string(forKey: key) != path else { return }
        Self.prefs.set(path, forKey: key)
        guard Self.prefs.object(forKey: "lastLoginItemStatus") as? Int == SMAppService.Status.enabled.rawValue else { return }
        try? SMAppService.mainApp.unregister()
        try? SMAppService.mainApp.register()
    }

    /// L'ouverture au démarrage désactivée ailleurs que dans KidSafe (Réglages Système) est notée pour le parent.
    private func noteLoginItemStatus(_ new: SMAppService.Status) {
        let key = "lastLoginItemStatus"
        let old = Self.prefs.object(forKey: key) as? Int
        if old == SMAppService.Status.enabled.rawValue, new != .enabled {
            EventLog.append(.init(date: Date(), kind: .loginItemDisabled), to: eventsFile)
            loadEvents()
        }
        Self.prefs.set(new.rawValue, forKey: key)
        loginItemStatus = new
    }

    func removePassword() {
        guard requireUnlock() else { return }
        removePasswordUnlocked()
    }

    /// Retour au fonctionnement sans mot de passe parent : propose aussi de désactiver
    /// les protections ajoutées avec lui (catégorie Contournement, règle Firefox).
    private func removePasswordUnlocked() {
        var choices: [(title: String, apply: () -> Void)] = []
        if let bypass = catalog.categories.first(where: { $0.id == "bypass" }), bypass.enabled {
            choices.append((L("protect.cleanup.bypass"), { self.mutate(locked: false) { try $0.setEnabled(bypass.id, false) } }))
        }
        if firefoxLocked {
            choices.append((L("protect.cleanup.firefox"), { self.setFirefoxLock(false, locked: false) }))
        }
        let picked = choices.isEmpty ? [] : checkboxAlert(title: L("protect.cleanup.title"), message: L("protect.cleanup.message"),
                                                           choices: choices.map(\.title), ok: L("protect.cleanup.ok"), cancel: L("protect.cleanup.keep"))
        mutate(locked: false, apply: false) { $0.parentPassword = nil; $0.blockWhenClosed = false }
        for (on, choice) in zip(picked ?? [], choices) where on { choice.apply() }
    }

    /// Alerte avec des cases cochées par défaut. Renvoie l'état des cases, ou nil si annulée.
    private func checkboxAlert(title: String, message: String, choices: [String], ok: String, cancel: String) -> [Bool]? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let boxes = choices.map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
        boxes.forEach { $0.state = .on }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(boxes.count) * 26)
        a.accessoryView = stack
        a.addButton(withTitle: ok)
        a.addButton(withTitle: cancel)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return boxes.map { $0.state == .on }
    }

    // MARK: - Ouverture au démarrage

    var launchAtLogin: Bool { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }

    /// Ouvre KidSafe à l'ouverture de session (Réglages Système → Général → Ouverture).
    /// Privoxy, lui, démarrera avec le Mac grâce au service système installé par le .pkg.
    func setLaunchAtLogin(_ on: Bool) {
        if !on { guard requireUnlock() else { return } }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = L("app.login.error", error.localizedDescription)
        }
        loginItemStatus = SMAppService.mainApp.status
        Self.prefs.set(loginItemStatus.rawValue, forKey: "lastLoginItemStatus")   // changement voulu : pas un événement
        if on, loginItemStatus == .requiresApproval {
            if confirm(title: L("app.login.approvalTitle"), message: L("app.login.approvalMessage"),
                       ok: L("app.login.openSettings"), style: .informational) {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    // MARK: - Filtrage

    func setFiltering(_ on: Bool) { setFiltering(on, until: nil) }

    /// Désactivation temporaire (protégée par le mot de passe parent) : le filtrage reprend tout seul.
    func pause(for seconds: TimeInterval) { setFiltering(false, until: Date().addingTimeInterval(seconds)) }

    /// `until` : fin d'une pause temporaire ; `locked` faux pour la reprise automatique.
    private func setFiltering(_ on: Bool, until: Date?, locked: Bool = true) {
        if locked { guard requireUnlock() else { return } }
        guard let installer else { lastError = L("app.error.noPrivoxy"); objectWillChange.send(); return }
        guard mutate(locked: false, apply: false, { $0.filteringEnabled = on; $0.pausedUntil = on ? nil : until }) else { return }
        now = Date()
        scheduleResume()
        if on {
            reconnectAfterApply = true
            applyNow()
        } else {
            pendingApply?.cancel()
            do { try engine.pause(catalog, installer: installer) } catch { lastError = "\(error)" }
        }
    }

    /// Minuterie de fin de pause (la vérification toutes les 30 s sert de filet, après une mise en veille par exemple).
    private func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        guard !catalog.filteringEnabled, let until = catalog.pausedUntil else { return }
        let t = Timer(fire: max(until, Date()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resumeIfPauseExpired() }
        }
        RunLoop.main.add(t, forMode: .common)
        resumeTimer = t
    }

    private func resumeIfPauseExpired() {
        guard catalog.pauseExpired(at: Date()) else { return }
        setFiltering(true, until: nil, locked: false)
    }

    func setRefreshHours(_ h: Int) { mutate(apply: false) { $0.refreshHours = h } }

    // MARK: - Listes

    func setEnabled(_ id: String, _ on: Bool) {
        guard let cat = catalog.categories.first(where: { $0.id == id }) else { return }
        guard requireUnlock() else { return }
        if on, let warning = cat.displayWarning {
            guard confirm(title: L("app.alert.heavy.title", cat.displayName), message: warning,
                          ok: L("app.alert.heavy.enable"), style: .warning) else { objectWillChange.send(); return }
        }
        mutate { try $0.setEnabled(id, on) }
    }

    /// Taille d'une liste à niveaux (léger / normal / renforcé) ; la liste est retéléchargée.
    func setLevel(_ id: String, _ level: ListLevel) {
        guard let cat = catalog.categories.first(where: { $0.id == id }), cat.level != level else { return }
        guard requireUnlock() else { objectWillChange.send(); return }
        if cat.enabled, let warning = Catalog.levelWarning(id, level) {
            guard confirm(title: L("app.alert.heavy.title", cat.displayName), message: L(warning),
                          ok: L("app.alert.heavy.enable"), style: .warning) else { objectWillChange.send(); return }
        }
        mutate(apply: cat.enabled) { try $0.setLevel(id, level) }
    }

    func setStrictMode(_ on: Bool) {
        guard requireUnlock() else { return }
        if on, catalog.allowlist.isEmpty {
            guard confirm(title: L("app.alert.strict.title"), message: L("app.alert.strict.message"),
                          ok: L("app.alert.strict.enable"), style: .warning) else { objectWillChange.send(); return }
        }
        mutate { $0.strictMode = on }
    }

    func addFromLibrary(_ preset: Catalog.Category) {
        mutate { try $0.addCustomList(id: preset.id, name: preset.name, sources: preset.sources, warning: preset.warning) }
    }

    func addFromURL(name: String, url: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces), u = url.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let parsed = URL(string: u), parsed.scheme?.lowercased() == "https", parsed.host != nil else {
            lastError = L("error.insecureURL", u)
            return false
        }
        let member = u.lowercased().hasSuffix(".tar.gz") || u.lowercased().hasSuffix(".tgz") ? archiveMemberGuess(u) : nil
        return mutate { try $0.addCustomList(id: $0.uniqueID(for: n), name: n, sources: [.init(url: u, archiveMember: member)]) }
    }

    /// Choix d'un fichier local, puis demande du nom de la liste.
    func addFromFile() {
        guard requireUnlock() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = L("app.addFile.panelTitle")
        panel.message = L("app.addFile.panelMessage")
        panel.prompt = L("app.addFile.choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .data]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let name = askText(title: L("app.addFile.nameTitle"), message: L("app.addFile.nameMessage"),
                                 initial: file.deletingPathExtension().lastPathComponent) else { return }
        let listsDir = engine.paths.listsDir
        var count = 0
        let ok = mutate { catalog in
            count = try catalog.addLocalList(file: file, id: catalog.uniqueID(for: name), name: name, listsDir: listsDir)
        }
        if ok { notice(L("app.addFile.done", formatCount(count), name)) }
    }

    func remove(_ id: String) {
        guard requireUnlock() else { return }
        guard let cat = catalog.categories.first(where: { $0.id == id }),
              confirm(title: L("app.alert.remove.title", cat.displayName), message: L("app.alert.remove.message"),
                      ok: L("app.alert.remove.ok"), style: .informational) else { return }
        let engine = self.engine
        mutate { try engine.removeCustomList(id, from: &$0) }
    }

    // MARK: - Domaines

    func addAllowed(_ raw: String) -> Bool { mutate { try $0.addAllowedDomain(raw) } }
    func removeAllowed(_ d: String) { mutate { $0.allowlist.removeAll { $0 == d } } }
    func addBlocked(_ raw: String) -> Bool { mutate { try $0.addBlockedDomain(raw) } }
    func removeBlocked(_ d: String) { mutate { $0.blockedDomains.removeAll { $0 == d } } }

    // MARK: - Réseaux sociaux

    func setServiceMode(_ id: String, _ mode: ServicePolicy.Mode) {
        mutate(fast: true) { c in
            var p = c.policy(for: id)
            if p.mode == mode { return }
            p.mode = mode
            if (mode == .blockedDuring || mode == .allowedOnlyDuring) && p.windows.isEmpty {
                p.windows = [ServicePolicy.defaultWindow(for: mode)]
            }
            c.services[id] = p
        }
    }

    func updateWindows(_ id: String, _ change: (inout [TimeWindow]) -> Void) {
        mutate(fast: true) { c in
            var p = c.policy(for: id)
            change(&p.windows)
            c.services[id] = p
        }
    }

    // MARK: - Réglages par défaut

    /// Onglet dont le bouton « Réglages par défaut… » a été cliqué.
    enum DefaultsScope: String { case lists, social, domains, general }

    /// Remet un onglet dans son état initial, après le mot de passe parent et une confirmation.
    /// Le mot de passe, les protections contre les contournements et l'onglet Avancé ne sont jamais touchés.
    func resetToDefaults(_ scope: DefaultsScope) {
        guard requireUnlock() else { return }
        var message = L("reset.\(scope.rawValue).message")
        if scope == .domains, catalog.strictMode, !catalog.allowlist.isEmpty { message += "\n\n" + L("reset.domains.strict") }
        guard confirm(title: L("reset.\(scope.rawValue).title"), message: message, ok: L("reset.ok"), style: .warning) else { return }
        let engine = self.engine
        switch scope {
        case .lists: _ = mutate(locked: false) { try engine.resetLists(&$0) }
        case .social: _ = mutate(locked: false, fast: true) { $0.resetSocial() }
        case .domains: _ = mutate(locked: false) { $0.resetDomains() }
        case .general:
            _ = mutate(locked: false) { $0.resetGeneral() }
            if !catalog.filteringEnabled { setFiltering(true, until: nil, locked: false) }
            if !launchAtLogin { setLaunchAtLogin(true) }
        }
    }

    // MARK: - Application

    /// Applique les changements après un court délai, pour grouper plusieurs clics.
    private func scheduleApply(delay: Int = 1200) {
        pendingApply?.cancel()
        pendingApply = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            self?.applyNow()
        }
    }

    func applyNow() {
        guard let installer else { lastError = L("app.error.noPrivoxy"); return }
        guard !isApplying else { scheduleApply(); return }
        isApplying = true
        lastError = nil
        let catalog = self.catalog, engine = self.engine
        // File principale (dans l'ordre d'envoi) : la dernière étape ne peut pas arriver après la fin.
        let progress: @Sendable (String, ListProgress) -> Void = { id, step in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.listProgress[id] = step } }
        }
        Task {
            defer { DispatchQueue.main.async { MainActor.assumeIsolated { self.listProgress = [:] } } }
            do {
                let result = try await engine.apply(catalog, installer: installer, progress: progress)
                self.status = result.status
                self.lastBlockedServiceIDs = Set(catalog.blockedServices(at: Date()).map(\.id))
                if self.reconnectAfterApply, catalog == self.catalog {
                    self.reconnectAfterApply = false
                    self.restartPrivoxy()
                }
                if !result.update.failed.isEmpty {
                    self.lastError = result.update.failed.map { "\($0.id) : \($0.error)" }.joined(separator: "\n")
                }
            } catch {
                self.lastError = "\(error)"
            }
            self.isApplying = false
            self.refreshSystemStatus()
        }
    }

    func refreshListsManually() {
        applyNow()
    }

    /// Résumé de la dernière mise à jour, en bas de l'onglet Listes.
    var listsSummaryLine: (text: String, failed: Bool)? {
        guard !catalog.strictMode, let when = status.lastApplied,
              let s = status.summary(for: catalog.categories.filter(\.enabled).map(\.id)) else { return nil }
        let failures = s.failed == 0 ? L("lists.summary.noFailure") : L("lists.summary.failures", s.failed)
        let time = formatDate(when, date: Calendar.current.isDateInToday(when) ? .omitted : .abbreviated, time: .shortened)
        return (L("lists.summary", time, s.updated, s.unchanged, failures), s.failed > 0)
    }

    func configureSystemProxy(_ enable: Bool) {
        makeController()
        guard let e = endpoint, let privoxy else { lastError = L("app.error.noPrivoxy"); return }
        if !enable {
            guard requireUnlock() else { return }
            guard confirm(title: L("app.alert.proxyOff.title"), message: L("app.alert.proxyOff.message"),
                          ok: L("app.alert.proxyOff.ok"), style: .warning) else { return }
            proxyWanted = false
            if let err = SystemStatus.setSystemProxy(e, enable: false, prompt: L("app.proxy.adminPromptOff")),
               !err.contains("-128") { lastError = L("app.error.proxy", err) }
            refreshSystemStatus()
            return
        }
        // Jamais de proxy vers un Privoxy arrêté : on le démarre d'abord.
        guard privoxy.start() else { lastError = L("app.error.privoxyStart"); refreshSystemStatus(); return }
        if let err = SystemStatus.setSystemProxy(e, enable: true, prompt: L("app.proxy.adminPrompt")) {
            if !err.contains("-128") { lastError = L("app.error.proxy", err) }   // -128 : annulé par l'utilisateur
        } else {
            proxyWanted = true
            lastError = nil
        }
        refreshSystemStatus()
    }

    // MARK: - Cycle de vie de Privoxy

    func makeController() {
        installer = installer ?? detectInstaller()
        guard privoxy == nil, let installer, let e = endpoint else { return }
        privoxy = PrivoxyController(binary: installer.privoxyBinary, configFile: installer.configFile, host: e.host, port: e.port,
                                    useLaunchAgent: !usesBundledPrivoxy)
    }

    /// Au lancement : démarre Privoxy puis, si le parent l'avait activé, remet le proxy du Mac.
    func startUp() {
        startHeartbeat()
        ensureFreePort()
        applyPrivoxyOptions()        // ex. journal des blocages requis par les notifications (versions précédentes)
        updateBlockNotifier()
        if catalog.recordsBlocks, let dir = installer?.confDir { BlockLog.trim(BlockLog.logFile(confDir: dir)) }
        makeController()
        guard let privoxy, let e = endpoint else { return }
        // Premier lancement (aucun choix enregistré) : la protection s'active toute seule.
        // Un retrait volontaire du proxy par le parent (proxyWanted = false) est respecté.
        let firstLaunch = Self.prefs.object(forKey: "proxyWanted") == nil
        let wanted = proxyWanted || firstLaunch
        let prompt: String? = firstLaunch ? L("app.proxy.adminPrompt") : nil
        healthBusy = true
        Task.detached {
            let ok = privoxy.start()
            let err = ok && wanted ? SystemStatus.setSystemProxy(e, enable: true, prompt: prompt) : nil
            await MainActor.run {
                self.healthBusy = false
                if !ok { self.lastError = L("app.error.privoxyStart") }
                if firstLaunch {
                    // Activée : on s'en souvient. Annulée ou refusée : on ne redemande pas à chaque lancement.
                    self.proxyWanted = ok && err == nil
                    if ok && err == nil { self.notice(L("app.welcome.enabled")) }
                    else if ok, let err, !err.contains("-128") { self.lastError = L("app.error.proxy", err) }
                } else if err != nil {
                    self.lastError = L("app.error.proxyAuto")
                }
                self.refreshSystemStatus()
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.healthCheck() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.announceUpdateIfNeeded() }
    }

    /// En quittant : retire d'abord le proxy, puis laisse Privoxy en simple relais (sans filtrer). Si le proxy
    /// ne peut pas être retiré, Privoxy reste allumé et filtre : le Mac ne doit jamais se retrouver sans connexion.
    /// Exception : le parent a choisi de couper internet sans KidSafe. Le proxy et Privoxy restent
    /// alors en place (déconnexion, redémarrage, mise à jour) ; seul « Quitter » avec le mot de passe les retire.
    func shutDown() {
        healthTimer?.invalidate()
        pendingApply?.cancel()
        Heartbeat.clear(heartbeatFile)
        guard !uninstalling, let e = endpoint else { return }
        if catalog.keepsProxyWhenClosed && !quitByParent { return }
        // setSystemProxy ne touche que les services qui pointent vers Privoxy (aucun : rien à faire).
        if SystemStatus.setSystemProxy(e, enable: false, prompt: L("app.proxy.adminPromptOff")) != nil {
            return
        }
        // Simple relais : certaines apps (Claude, VS Code…) mémorisent l'adresse du proxy à leur lancement
        // et perdraient internet si Privoxy s'arrêtait. Il reste allumé sans rien filtrer jusqu'à la fin
        // de la session ; KidSafe le reprend au lancement suivant, le désinstalleur l'arrête.
        if usesBundledPrivoxy, let installer {
            var relay = PrivoxyConfigEditor.Options(catalog: catalog)
            relay.relay = true
            if (try? installer.updateOptions(relay)) != nil { return }
        }
        privoxy?.stop()
    }

    /// Toutes les 5 s. Proxy actif mais Privoxy arrêté = plus de connexion : on relance Privoxy,
    /// et s'il ne repart pas, on retire le proxy. Le proxy est remis dès que Privoxy répond.
    private func healthCheck() {
        guard !healthBusy, !uninstalling, let e = endpoint, let privoxy else { return }
        let listening = SystemStatus.isListening(e)
        let pointing = SystemStatus.systemProxyPointsTo(e)
        privoxyRunning = listening
        systemProxyOK = pointing
        let wanted = proxyWanted
        let mayRetryProxy = lastAutoProxyFailure.map { Date().timeIntervalSince($0) > 300 } ?? true

        if pointing && !listening {
            healthBusy = true
            // Internet coupé sans KidSafe : le proxy reste, même si Privoxy ne repart pas.
            let keep = catalog.keepsProxyWhenClosed
            Task.detached {
                let ok = privoxy.start(timeout: 4)
                if !ok && !keep { SystemStatus.setSystemProxy(e, enable: false, prompt: nil) }
                await MainActor.run {
                    self.healthBusy = false
                    self.refreshSystemStatus()
                    if !ok { keep ? self.privoxyDownNotice() : self.safetyNotice() }
                }
            }
        } else if wanted && !pointing && mayRetryProxy {
            healthBusy = true
            Task.detached {
                let ok = privoxy.start(timeout: 4)
                let err = ok ? SystemStatus.setSystemProxy(e, enable: true, prompt: nil) : "privoxy"
                await MainActor.run {
                    self.healthBusy = false
                    if err != nil { self.lastAutoProxyFailure = Date() }
                    self.refreshSystemStatus()
                }
            }
        }
    }

    private func privoxyDownNotice() {
        lastError = L("app.safety.kept")
        guard !privoxyDownNoticeShown else { return }
        privoxyDownNoticeShown = true
        notice(L("app.safety.kept"))
    }

    private func safetyNotice() {
        lastError = L("app.safety.removed")
        guard !safetyNoticeShown else { return }
        safetyNoticeShown = true
        notice(L("app.safety.removed"))
    }

    func restartPrivoxy() {
        guard let privoxy else { return }
        healthBusy = true
        Task.detached {
            privoxy.restart()
            await MainActor.run { self.healthBusy = false; self.refreshSystemStatus() }
        }
    }

    /// Remet le Mac dans son état d'origine et place KidSafe dans la corbeille.
    func uninstall() {
        guard requireUnlock() else { return }
        guard confirm(title: L("app.uninstall.title"), message: L("app.uninstall.message"),
                      ok: L("app.uninstall.ok"), style: .critical) else { return }
        healthTimer?.invalidate()
        pendingApply?.cancel()
        if let e = endpoint, !SystemStatus.servicesUsingProxy(e).isEmpty,
           let err = SystemStatus.setSystemProxy(e, enable: false, prompt: L("app.proxy.adminPromptOff")) {
            // Sans retrait du proxy, on n'arrête pas Privoxy (sinon plus de connexion).
            notice(L("app.uninstall.proxyFailed", err))
            healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.healthCheck() }
            }
            return
        }
        uninstalling = true
        privoxy?.stop()
        let endpoints = [endpoint].compactMap { $0 }
        _ = KidSafeUninstaller.perform(paths: engine.paths, endpoints: endpoints, adminPrompt: nil)
        if FirefoxPolicy.isInstalled { _ = FirefoxPolicy.remove(prompt: L("firefox.adminPromptOff")) }
        try? SMAppService.mainApp.unregister()
        let app = Bundle.main.bundleURL
        if app.pathExtension == "app" { NSWorkspace.shared.recycle([app]) { _, _ in } }
        notice(L("app.uninstall.done"))
        NSApp.terminate(nil)
    }

    /// Fourni par l'AppDelegate.
    var openSettingsHandler: (() -> Void)?
    func openSettings() { openSettingsHandler?() }

    // MARK: - Nouvelles versions de KidSafe

    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    /// Étiquette de version (clé `KidSafeReleaseLabel`, ex. « beta » ; vide pour une version finale).
    let releaseLabel = Bundle.main.object(forInfoDictionaryKey: "KidSafeReleaseLabel") as? String ?? ""
    /// « KidSafe 0.3.3 (beta) », affiché en bas du menu.
    var versionLabel: String { "\(Brand.name) \(appVersion)" + (releaseLabel.isEmpty ? "" : " (\(releaseLabel))") }
    /// KIDSAFE_UPDATE_API (tests) remplace l'adresse définie à la construction.
    private let updateChecker: UpdateChecker? = (ProcessInfo.processInfo.environment["KIDSAFE_UPDATE_API"]
        ?? Bundle.main.object(forInfoDictionaryKey: "KidSafeUpdateAPI") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }.map(UpdateChecker.init)
    @Published private(set) var isInstallingUpdate = false
    /// Installer sans demander les nouvelles versions trouvées par la recherche hebdomadaire (activé par défaut).
    @Published var autoInstallUpdates: Bool = AppModel.prefs.object(forKey: "autoInstallUpdates") as? Bool ?? true {
        didSet { AppModel.prefs.set(autoInstallUpdates, forKey: "autoInstallUpdates") }
    }
    /// L'app installée ici peut-elle se remplacer elle-même (dossier modifiable, pas sur le .dmg) ?
    var canAutoInstall: Bool { AppUpdater.canReplace(Bundle.main.bundleURL) }
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var availableUpdate: UpdateChecker.Release?
    @Published private(set) var lastUpdateCheck: Date? = AppModel.prefs.object(forKey: "lastUpdateCheck") as? Date
    /// Recherche automatique, une fois par semaine (activée par défaut).
    @Published var autoUpdateCheck: Bool = AppModel.prefs.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { AppModel.prefs.set(autoUpdateCheck, forKey: "autoUpdateCheck") }
    }
    static let updateCheckInterval: TimeInterval = 7 * 24 * 3600
    var canCheckUpdates: Bool { updateChecker != nil }

    /// `manual` : affiche toujours le résultat. Sinon (recherche hebdomadaire), ne prévient
    /// que d'une version nouvelle, une seule fois par version, et reste silencieuse en cas d'erreur.
    func checkForUpdates(manual: Bool = true) {
        guard let updateChecker, !isCheckingUpdates else { return }
        isCheckingUpdates = true
        let current = appVersion
        Task {
            let result: Result<UpdateChecker.Release, Error>
            do { result = .success(try await updateChecker.latest(userAgent: "\(Brand.name)/\(current)")) } catch { result = .failure(error) }
            self.isCheckingUpdates = false
            self.lastUpdateCheck = Date()
            AppModel.prefs.set(self.lastUpdateCheck, forKey: "lastUpdateCheck")
            switch result {
            case .success(let release) where UpdateChecker.isNewer(release.version, than: current):
                self.availableUpdate = release
                let notified = AppModel.prefs.string(forKey: "notifiedVersion")
                if !manual, self.autoInstallUpdates, release.dmgSHA256 != nil, self.canAutoInstall {
                    self.installUpdate(release, silent: true)
                } else if manual || notified != release.version {
                    AppModel.prefs.set(release.version, forKey: "notifiedVersion")
                    self.offerUpdate(release)
                }
            case .success:
                self.availableUpdate = nil
                if manual { self.notice(L("updates.upToDate", current)) }
            case .failure(let error):
                if manual { self.notice(L("updates.error", "\(error)")) }
            }
        }
    }

    func offerUpdate(_ release: UpdateChecker.Release) {
        NSApp.activate(ignoringOtherApps: true)
        let canInstall = release.dmgSHA256 != nil && canAutoInstall
        let a = NSAlert()
        a.messageText = L("updates.available.title", release.version)
        a.informativeText = canInstall ? L("autoupdate.message", appVersion) : L("updates.available.message", appVersion)
        var actions: [() -> Void] = []
        if canInstall {
            a.addButton(withTitle: L("autoupdate.install")); actions.append { self.installUpdate(release, silent: false) }
        }
        a.addButton(withTitle: L("updates.download")); actions.append { NSWorkspace.shared.open(release.downloadURL ?? release.pageURL) }
        a.addButton(withTitle: L("updates.notes")); actions.append { NSWorkspace.shared.open(release.pageURL) }
        a.addButton(withTitle: L("updates.later")); actions.append {}
        let index = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(index) { actions[index]() }
    }

    /// Télécharge, vérifie, puis quitte : un script remplace l'app et la relance.
    /// Le filtre est retiré et Privoxy arrêté pendant les quelques secondes du remplacement.
    func installUpdate(_ release: UpdateChecker.Release, silent: Bool) {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        let current = appVersion, bundleID = Bundle.main.bundleIdentifier ?? KidSafeUninstaller.bundleID
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("yamoxy-update-\(release.version)")
        Task {
            do {
                let staged = try await AppUpdater.prepare(release, currentVersion: current, bundleID: bundleID,
                                                              requiredTeamID: AppUpdater.teamID(of: Bundle.main.bundleURL),
                                                              stagingDir: staging)
                let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("KIDSAFE_") }
                try AppUpdater.scheduleReplace(current: Bundle.main.bundleURL, staged: staged, stagingDir: staging,
                                               pid: ProcessInfo.processInfo.processIdentifier, env: env)
                AppModel.prefs.set(current, forKey: "updatedFrom")
                NSApp.terminate(nil)   // shutDown (filtre retiré, sauf « Couper internet ») ; le script fait le reste.
            } catch {
                self.isInstallingUpdate = false
                try? FileManager.default.removeItem(at: staging)
                if silent {
                    self.lastError = L("autoupdate.failed", "\(error)")
                } else {
                    self.notice(L("autoupdate.failed", "\(error)"))
                }
            }
        }
    }

    /// Après une mise à jour : un message discret confirme la nouvelle version.
    func announceUpdateIfNeeded() {
        guard let from = AppModel.prefs.string(forKey: "updatedFrom") else { return }
        AppModel.prefs.removeObject(forKey: "updatedFrom")
        guard UpdateChecker.isNewer(appVersion, than: from) else { return }
        availableUpdate = nil
        notice(L("autoupdate.done", appVersion, from))
    }

    /// Contact pour les avis, défini à la construction (clés `KidSafeFeedbackEmail` et `KidSafeIssuesURL`).
    let feedbackEmail: String? = (Bundle.main.object(forInfoDictionaryKey: "KidSafeFeedbackEmail") as? String).flatMap { $0.isEmpty ? nil : $0 }
    let issuesURL: URL? = (Bundle.main.object(forInfoDictionaryKey: "KidSafeIssuesURL") as? String)
        .flatMap { $0.isEmpty ? nil : URL(string: $0) }
    /// Liens publics, définis à la construction (clés `KidSafeWebsiteURL` et `KidSafeSourceURL`).
    let websiteURL: URL? = AppModel.infoURL("KidSafeWebsiteURL")
    let sourceURL: URL? = AppModel.infoURL("KidSafeSourceURL")
    private static func infoURL(_ key: String) -> URL? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }
    func open(_ url: URL?) { if let url { NSWorkspace.shared.open(url) } }

    var canSendFeedback: Bool { feedbackEmail != nil || issuesURL != nil }

    /// E-mail prérempli avec la version de KidSafe et de macOS (rien d'autre n'est joint).
    func sendFeedbackByEmail() {
        guard let to = feedbackEmail else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = to
        c.queryItems = [URLQueryItem(name: "subject", value: L("app.feedback.subject", version)),
                        URLQueryItem(name: "body", value: L("app.feedback.body", version, os))]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Copie l'adresse dans le presse-papiers (si les liens e-mail n'ouvrent pas de messagerie).
    func copyFeedbackEmail() {
        guard let to = feedbackEmail else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(to, forType: .string)
        notice(L("app.feedback.copied", to))
    }

    func sendFeedbackOnGitHub() {
        if let issuesURL { NSWorkspace.shared.open(issuesURL) }
    }

    /// Page interne de Privoxy : elle ne s'affiche que si le navigateur passe bien par Privoxy.
    func openPrivoxyTestPage() {
        if let url = URL(string: "http://p.p/") { NSWorkspace.shared.open(url) }
    }

    func donate() {
        if let donateURL { NSWorkspace.shared.open(donateURL) }
    }

    /// Quitter arrête les plages horaires (le filtrage, lui, continue) : protégé par le mot de passe.
    func quit() {
        guard requireUnlock() else { return }
        quitByParent = true
        NSApp.terminate(nil)
    }

    // MARK: - Aides

    /// Modifie le catalogue, l'enregistre et planifie son application.
    /// `locked` : demande le mot de passe parent ; `fast` : application presque immédiate.
    @discardableResult
    func mutate(locked: Bool = true, apply: Bool = true, fast: Bool = false, _ change: (inout Catalog) throws -> Void) -> Bool {
        if locked, !requireUnlock() { return false }
        var copy = catalog
        do {
            try change(&copy)
            guard copy != catalog else { return true }
            try engine.save(copy)
            catalog = copy
            lastError = nil
            if apply, catalog.filteringEnabled {
                reconnectAfterApply = true
                scheduleApply(delay: fast ? 400 : 1200)
            }
            return true
        } catch {
            lastError = "\(error)"
            objectWillChange.send()
            return false
        }
    }

    private func archiveMemberGuess(_ url: String) -> String? {
        // UT1 : https://…/download/adult.tar.gz → adult/domains
        let file = URL(string: url)?.lastPathComponent ?? ""
        let base = file.replacingOccurrences(of: ".tar.gz", with: "").replacingOccurrences(of: ".tgz", with: "")
        return base.isEmpty ? nil : base + "/domains"
    }

    func confirm(title: String, message: String, ok: String, style: NSAlert.Style) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: L("app.cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    func notice(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = Brand.name
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func askText(title: String, message: String, initial: String) -> String? {
        ask(title: title, message: message, ok: L("app.add"), field: NSTextField(string: initial))
    }

    private func askSecret(title: String, message: String, ok: String) -> String? {
        ask(title: title, message: message, ok: ok, field: NSSecureTextField(string: ""))
    }

    /// Variante avec un troisième bouton (ex. « Mot de passe oublié ? ») : `extra` vrai s'il a été choisi.
    private func askSecret(title: String, message: String, ok: String, extra: String) -> (value: String?, extra: Bool) {
        var pressedExtra = false
        let v = ask(title: title, message: message, ok: ok, field: NSSecureTextField(string: ""), extra: extra) { pressedExtra = true }
        return (v, pressedExtra)
    }

    private func ask(title: String, message: String, ok: String, field: NSTextField,
                     extra: String? = nil, onExtra: () -> Void = {}) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: ok)
        a.addButton(withTitle: L("app.cancel"))
        if let extra { a.addButton(withTitle: extra) }
        a.window.initialFirstResponder = field
        let response = a.runModal()
        if response == .alertThirdButtonReturn { onExtra(); return nil }
        guard response == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
