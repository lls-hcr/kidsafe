import CommonCrypto
import Foundation

/// Empreinte PBKDF2-SHA256 du mot de passe parent (le mot de passe lui-même n'est jamais enregistré).
public struct PasswordHash: Codable, Sendable, Equatable {
    public var salt: String        // base64
    public var hash: String        // base64
    public var iterations: Int

    public static let defaultIterations = 210_000

    public static func make(_ password: String, iterations: Int = defaultIterations) -> PasswordHash {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let h = derive(password, salt: salt, iterations: iterations)
        return PasswordHash(salt: Data(salt).base64EncodedString(), hash: Data(h).base64EncodedString(), iterations: iterations)
    }

    public func verify(_ password: String) -> Bool {
        guard let s = Data(base64Encoded: salt), let expected = Data(base64Encoded: hash) else { return false }
        let h = Self.derive(password, salt: [UInt8](s), iterations: iterations)
        // Comparaison en temps constant.
        guard h.count == expected.count else { return false }
        return zip(h, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        _ = pw.withUnsafeBufferPointer { p in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &out, out.count)
        }
        return out
    }
}
