import CryptoKit
import Foundation
import Security

/// Mise à jour automatique de KidSafe : téléchargement du .dmg, vérifications, puis remplacement
/// de l'app une fois qu'elle a quitté (elle retire d'abord le filtre et arrête Privoxy), et relance.
///
/// Vérifications avant toute installation :
/// 1. empreinte SHA-256 du .dmg identique à celle publiée par GitHub ;
/// 2. le .dmg contient bien l'app (KidSafe.app ou Yamoxy.app, même identifiant) dans une version plus récente ;
/// 3. la signature de l'app copiée est intacte (`codesign --verify`) ;
/// 4. si l'app en cours est signée avec un Developer ID, la nouvelle doit l'être par le même développeur (Team ID).
public enum AppUpdater {
    public enum UpdateError: Error, CustomStringConvertible {
        case noChecksum, noDownload, checksumMismatch, notKidSafe, notNewer(String), tool(String), notWritable(String), wrongSigner
        public var description: String {
            switch self {
            case .noChecksum: return L("autoupdate.error.noChecksum")
            case .noDownload: return L("autoupdate.error.noDownload")
            case .checksumMismatch: return L("autoupdate.error.checksum")
            case .notKidSafe: return L("autoupdate.error.notKidSafe")
            case .notNewer(let v): return L("autoupdate.error.notNewer", v)
            case .tool(let why): return why
            case .notWritable(let p): return L("autoupdate.error.notWritable", p)
            case .wrongSigner: return L("autoupdate.error.signer")
            }
        }
    }

    /// L'app peut-elle être remplacée sans mot de passe administrateur ?
    public static func canReplace(_ app: URL) -> Bool {
        let fm = FileManager.default
        return app.pathExtension == "app" && !app.path.hasPrefix("/Volumes/")
            && fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    /// Télécharge et vérifie la nouvelle version, puis la copie dans `stagingDir`, sous son nom du .dmg
    /// (`KidSafe.app` ou `Yamoxy.app`).
    /// `requiredTeamID` : Team ID de l'app en cours (`nil` pour une app signée ad hoc : pas d'exigence).
    public static func prepare(_ release: UpdateChecker.Release, currentVersion: String, bundleID: String,
                               requiredTeamID: String? = nil, stagingDir: URL) async throws -> URL {
        guard let expected = release.dmgSHA256 else { throw UpdateError.noChecksum }
        guard let url = release.downloadURL else { throw UpdateError.noDownload }
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dmg = stagingDir.appendingPathComponent("Yamoxy.dmg")

        if url.isFileURL {
            try fm.copyItem(at: url, to: dmg)
        } else {
            let (tmp, response) = try await KidSafeHTTP.session.download(from: url)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                throw UpdateError.noDownload
            }
            try fm.moveItem(at: tmp, to: dmg)
        }
        let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
        guard digest.map({ String(format: "%02x", $0) }).joined() == expected else { throw UpdateError.checksumMismatch }

        let mount = stagingDir.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        guard let (newApp, info) = app(in: mount, bundleID: bundleID) else { throw UpdateError.notKidSafe }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        guard UpdateChecker.isNewer(newVersion, than: currentVersion) else { throw UpdateError.notNewer(newVersion) }

        // Même nom que dans le .dmg : `KidSafe.app` aujourd'hui, `Yamoxy.app` après le changement de nom.
        let staged = stagingDir.appendingPathComponent(newApp.lastPathComponent)
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", staged.path])
        if let requiredTeamID, teamID(of: staged) != requiredTeamID { throw UpdateError.wrongSigner }
        return staged
    }

    /// Noms d'app acceptés dans le .dmg, dans l'ordre de préférence (KidSafe devient Yamoxy).
    static let appNames = ["Yamoxy.app", "KidSafe.app"]

    /// L'app du .dmg monté : la première des `appNames` qui porte le même identifiant que l'app en cours.
    static func app(in mount: URL, bundleID: String) -> (URL, NSDictionary)? {
        for name in appNames {
            let candidate = mount.appendingPathComponent(name)
            if let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
               info["CFBundleIdentifier"] as? String == bundleID { return (candidate, info) }
        }
        return nil
    }

    /// Yamoxy installé à la main (glissé depuis le .dmg) : l'ancienne `KidSafe.app` peut rester à côté.
    /// Renvoie les copies à mettre à la corbeille : même identifiant, version plus ancienne, jamais l'app en cours.
    public static func leftoverOldApps(current: URL, bundleID: String, version: String, in dirs: [URL]) -> [URL] {
        let me = current.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [URL] = [], seen: Set<String> = []
        for dir in dirs {
            let candidate = dir.appendingPathComponent("KidSafe.app")
            let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != me, seen.insert(path).inserted,
                  let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == bundleID,
                  let old = info["CFBundleShortVersionString"] as? String,
                  UpdateChecker.isNewer(version, than: old) else { continue }
            found.append(candidate)
        }
        return found
    }

    /// Team ID du développeur qui a signé l'app (`nil` : signature ad hoc ou absente).
    public static func teamID(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Lance, détaché de l'app, le script qui attend la fin de l'app, remplace `current` par `staged`
    /// et relance l'app. En cas d'échec, l'ancienne version est remise en place et relancée.
    /// `env` : variables KIDSAFE_* à transmettre à l'app relancée (tests). `relaunch` : faux dans les tests.
    public static func scheduleReplace(current: URL, staged: URL, stagingDir: URL, pid: Int32, env: [String: String] = [:],
                                       relaunch: Bool = true) throws {
        guard canReplace(current) else { throw UpdateError.notWritable(current.path) }
        let script = replaceScript(current: current, staged: staged, stagingDir: stagingDir, pid: pid, env: env, relaunch: relaunch)
        let file = stagingDir.appendingPathComponent("replace.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        // Double « fork » via nohup + & : le script survit à la fermeture de l'app.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/usr/bin/nohup /bin/sh \(shellQuote(file.path)) >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Script de remplacement. La nouvelle app garde son nom du .dmg, dans le même dossier que l'ancienne :
    /// `/Applications/KidSafe.app` remplacée par `/Applications/Yamoxy.app` (l'ancienne disparaît).
    /// Si une app porte déjà le nouveau nom à cet endroit, on n'y touche pas : la mise à jour se fait
    /// sous l'ancien nom, comme avant. En cas d'échec, l'ancienne app est remise en place, à son nom ;
    /// si elle ne peut même pas être déplacée, rien n'est touché.
    static func replaceScript(current: URL, staged: URL, stagingDir: URL, pid: Int32, env: [String: String],
                              relaunch: Bool) -> String {
        let envArgs = env.sorted { $0.key < $1.key }.map { "--env " + shellQuote("\($0.key)=\($0.value)") }.joined(separator: " ")
        let dest = current.deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent)
        return """
        #!/bin/sh
        # Remplacement de l'app après sa fermeture, puis relance.
        CUR=\(shellQuote(current.path)); NEW=\(shellQuote(staged.path)); DEST=\(shellQuote(dest.path)); OLD="$CUR.yamoxy-old"
        i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
        [ "$DEST" != "$CUR" ] && [ -e "$DEST" ] && DEST="$CUR"
        rm -rf "$OLD"
        APP="$CUR"
        if mv "$CUR" "$OLD"; then
          if /usr/bin/ditto "$NEW" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
            rm -rf "$OLD"
            APP="$DEST"
          else
            rm -rf "$DEST"; mv "$OLD" "$CUR"
          fi
        fi
        \(relaunch ? "/usr/bin/open \"$APP\" \(envArgs)" : ": pas de relance")
        rm -rf \(shellQuote(stagingDir.path))
        """
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.tool("\((tool as NSString).lastPathComponent) : " + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self)
    }
}
