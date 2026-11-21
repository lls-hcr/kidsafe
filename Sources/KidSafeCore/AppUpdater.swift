import CryptoKit
import Foundation
import Security

/// Mise à jour automatique de KidSafe : téléchargement du .dmg, vérifications, puis remplacement
/// de l'app une fois qu'elle a quitté (elle retire d'abord le filtre et arrête Privoxy), et relance.
///
/// Vérifications avant toute installation :
/// 1. empreinte SHA-256 du .dmg identique à celle publiée par GitHub ;
/// 2. le .dmg contient bien KidSafe (même identifiant d'app) dans une version plus récente ;
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

    /// Télécharge et vérifie la nouvelle version, puis la copie dans `stagingDir/KidSafe.app`.
    /// `requiredTeamID` : Team ID de l'app en cours (`nil` pour une app signée ad hoc : pas d'exigence).
    public static func prepare(_ release: UpdateChecker.Release, currentVersion: String, bundleID: String,
                               requiredTeamID: String? = nil, stagingDir: URL) async throws -> URL {
        guard let expected = release.dmgSHA256 else { throw UpdateError.noChecksum }
        guard let url = release.downloadURL else { throw UpdateError.noDownload }
        let fm = FileManager.default
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let dmg = stagingDir.appendingPathComponent("KidSafe.dmg")

        if url.isFileURL {
            try fm.copyItem(at: url, to: dmg)
        } else {
            let (tmp, response) = try await URLSession.shared.download(from: url)
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

        let newApp = mount.appendingPathComponent("KidSafe.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else { throw UpdateError.notKidSafe }
        let newVersion = info["CFBundleShortVersionString"] as? String ?? "?"
        guard UpdateChecker.isNewer(newVersion, than: currentVersion) else { throw UpdateError.notNewer(newVersion) }

        let staged = stagingDir.appendingPathComponent("KidSafe.app")
        try run("/usr/bin/ditto", [newApp.path, staged.path])
        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", staged.path])
        if let requiredTeamID, teamID(of: staged) != requiredTeamID { throw UpdateError.wrongSigner }
        return staged
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
    /// et relance KidSafe. En cas d'échec, l'ancienne version est remise en place et relancée.
    /// `env` : variables KIDSAFE_* à transmettre à l'app relancée (tests).
    public static func scheduleReplace(current: URL, staged: URL, stagingDir: URL, pid: Int32, env: [String: String] = [:]) throws {
        guard canReplace(current) else { throw UpdateError.notWritable(current.path) }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let envArgs = env.sorted { $0.key < $1.key }.map { "--env " + q("\($0.key)=\($0.value)") }.joined(separator: " ")
        let script = """
        #!/bin/sh
        # KidSafe : remplacement de l'app après sa fermeture, puis relance.
        CUR=\(q(current.path)); NEW=\(q(staged.path)); OLD="$CUR.kidsafe-old"
        i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
        rm -rf "$OLD"
        if mv "$CUR" "$OLD" && /usr/bin/ditto "$NEW" "$CUR"; then
          /usr/bin/xattr -dr com.apple.quarantine "$CUR" 2>/dev/null
          rm -rf "$OLD"
        else
          rm -rf "$CUR"; mv "$OLD" "$CUR"
        fi
        /usr/bin/open "$CUR" \(envArgs)
        rm -rf \(q(stagingDir.path))
        """
        let file = stagingDir.appendingPathComponent("replace.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        // Double « fork » via nohup + & : le script survit à la fermeture de l'app.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "/usr/bin/nohup /bin/sh \(q(file.path)) >/dev/null 2>&1 &"]
        try p.run()
        p.waitUntilExit()
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
