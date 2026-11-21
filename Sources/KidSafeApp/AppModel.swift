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
    @Published private(set) var installer: PrivoxyInstaller?
    @Published private(set) var privoxyRunning = false
    @Published private(set) var systemProxyOK = false
    @Published private(set) var isApplying = false
    @Published private(set) var lastError: String?
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
    /// Privoxy, démarré par l'app au lancement et arrêté quand elle quitte.
    private(set) var privoxy: PrivoxyController?
    private var healthTimer: Timer?
    private var healthBusy = false
    private var lastAutoProxyFailure: Date?
    private var safetyNoticeShown = false
    private var uninstalling = false
    /// Le parent a branché le Mac sur Privoxy : KidSafe remet le proxy à chaque lancement
    /// et le retire toujours en quittant, avant d'arrêter Privoxy.
    private var proxyWanted: Bool {
        get { AppModel.prefs.bool(forKey: "proxyWanted") }
        set { AppModel.prefs.set(newValue, forKey: "proxyWanted") }
    }
    /// Réseaux sociaux bloqués lors de la dernière vérification des plages horaires.
    private var lastBlockedServiceIDs: Set<String> = []
    private var timer: Timer?

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
                if let inst = try BundledPrivoxy.prepare(supportDir: engine.paths.supportDir) {
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
        engine = KidSafeEngine(paths: Self.env["KIDSAFE_SUPPORT_DIR"].map { KidSafePaths(supportDir: URL(fileURLWithPath: $0)) } ?? .user)
        catalog = (try? engine.loadCatalog()) ?? .default
        status = engine.loadStatus()
        installer = detectInstaller()
        refreshSystemStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
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
        if let until = unlockedUntil, until <= now { unlockedUntil = nil }
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
        if Int(now.timeIntervalSince1970) % 300 < 30 {
            refreshSystemStatus()
            loginItemStatus = SMAppService.mainApp.status
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
            guard let pw = askSecret(title: L("app.lock.title"), message: L("app.lock.message"), ok: L("app.lock.unlock")) else {
                objectWillChange.send()
                return false
            }
            if hash.verify(pw) {
                unlockedUntil = Date().addingTimeInterval(Self.unlockDuration)
                now = Date()
                return true
            }
            NSSound.beep()
        }
    }

    func lock() { unlockedUntil = nil }

    func setPassword() {
        guard requireUnlock() else { return }
        guard let pw = askSecret(title: L("app.password.newTitle"), message: L("app.password.newMessage"), ok: L("app.password.save")),
              !pw.isEmpty else { return }
        guard let again = askSecret(title: L("app.password.confirmTitle"), message: "", ok: L("app.password.save")) else { return }
        guard pw == again else { notice(L("app.password.mismatch")); return }
        let hash = PasswordHash.make(pw)
        mutate(locked: false, apply: false) { $0.parentPassword = hash }
        unlockedUntil = Date().addingTimeInterval(Self.unlockDuration)
    }

    func removePassword() {
        guard requireUnlock() else { return }
        mutate(locked: false, apply: false) { $0.parentPassword = nil }
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
        if on, loginItemStatus == .requiresApproval {
            if confirm(title: L("app.login.approvalTitle"), message: L("app.login.approvalMessage"),
                       ok: L("app.login.openSettings"), style: .informational) {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    // MARK: - Filtrage

    func setFiltering(_ on: Bool) {
        guard requireUnlock() else { return }
        guard let installer else { lastError = L("app.error.noPrivoxy"); objectWillChange.send(); return }
        guard mutate(locked: false, apply: false, { $0.filteringEnabled = on }) else { return }
        if on {
            reconnectAfterApply = true
            applyNow()
        } else {
            pendingApply?.cancel()
            do { try engine.pause(catalog, installer: installer) } catch { lastError = "\(error)" }
        }
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
        Task {
            do {
                let result = try await engine.apply(catalog, installer: installer)
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

    private func makeController() {
        installer = installer ?? detectInstaller()
        guard privoxy == nil, let installer, let e = endpoint else { return }
        privoxy = PrivoxyController(binary: installer.privoxyBinary, configFile: installer.configFile, host: e.host, port: e.port,
                                    useLaunchAgent: !usesBundledPrivoxy)
    }

    /// Au lancement : démarre Privoxy puis, si le parent l'avait activé, remet le proxy du Mac.
    func startUp() {
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

    /// En quittant : retire d'abord le proxy, puis arrête Privoxy. Si le proxy ne peut pas
    /// être retiré, Privoxy reste allumé : le Mac ne doit jamais se retrouver sans connexion.
    func shutDown() {
        healthTimer?.invalidate()
        pendingApply?.cancel()
        guard !uninstalling, let e = endpoint else { return }
        // setSystemProxy ne touche que les services qui pointent vers Privoxy (aucun : rien à faire).
        if SystemStatus.setSystemProxy(e, enable: false, prompt: L("app.proxy.adminPromptOff")) != nil {
            return
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
            Task.detached {
                let ok = privoxy.start(timeout: 4)
                if !ok { SystemStatus.setSystemProxy(e, enable: false, prompt: nil) }
                await MainActor.run {
                    self.healthBusy = false
                    self.refreshSystemStatus()
                    if !ok { self.safetyNotice() }
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

    private func safetyNotice() {
        lastError = L("app.safety.removed")
        guard !safetyNoticeShown else { return }
        safetyNoticeShown = true
        notice(L("app.safety.removed"))
    }

    private func restartPrivoxy() {
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
    var versionLabel: String { "KidSafe \(appVersion)" + (releaseLabel.isEmpty ? "" : " (\(releaseLabel))") }
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
            do { result = .success(try await updateChecker.latest(userAgent: "KidSafe/\(current)")) } catch { result = .failure(error) }
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
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("kidsafe-update-\(release.version)")
        Task {
            do {
                let staged = try await AppUpdater.prepare(release, currentVersion: current, bundleID: bundleID, stagingDir: staging)
                let env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("KIDSAFE_") }
                try AppUpdater.scheduleReplace(current: Bundle.main.bundleURL, staged: staged, stagingDir: staging,
                                               pid: ProcessInfo.processInfo.processIdentifier, env: env)
                AppModel.prefs.set(current, forKey: "updatedFrom")
                NSApp.terminate(nil)   // shutDown : filtre retiré, Privoxy arrêté ; le script fait le reste.
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
        NSApp.terminate(nil)
    }

    // MARK: - Aides

    /// Modifie le catalogue, l'enregistre et planifie son application.
    /// `locked` : demande le mot de passe parent ; `fast` : application presque immédiate.
    @discardableResult
    private func mutate(locked: Bool = true, apply: Bool = true, fast: Bool = false, _ change: (inout Catalog) throws -> Void) -> Bool {
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

    private func confirm(title: String, message: String, ok: String, style: NSAlert.Style) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: L("app.cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }

    private func notice(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "KidSafe"
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

    private func ask(title: String, message: String, ok: String, field: NSTextField) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: ok)
        a.addButton(withTitle: L("app.cancel"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}
