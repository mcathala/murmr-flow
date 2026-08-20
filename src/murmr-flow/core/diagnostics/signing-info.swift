import Foundation
import Security

/// The app's own code signature, read at runtime.
///
/// This exists to make the Phase 0 gate *observable*. macOS ties TCC permission
/// grants to the code signature, and the matching mechanism depends on how the app
/// was signed:
///
///   - **Ad-hoc** (`codesign -s -`): no Team ID, so TCC identifies the app by its
///     CDHash — which changes on *every build*. Permissions reset constantly.
///   - **Real certificate** (Apple Development / Developer ID): stable Team ID, so
///     TCC matches on the designated requirement instead. The CDHash can change
///     freely and the grants survive.
///
/// So the test is: rebuild, watch the CDHash change, and confirm the Team ID stays
/// put while permissions hold.
struct SigningInfo: Sendable {
    var identifier: String?
    var teamID: String?
    var cdHash: String?
    var isAdHoc: Bool

    static let unknown = SigningInfo(identifier: nil, teamID: nil, cdHash: nil, isAdHoc: true)

    /// True when the signature is one TCC can track stably across rebuilds.
    var isStableForTCC: Bool { !isAdHoc && teamID != nil }

    var summary: String {
        if isAdHoc { return "Ad-hoc — permissions WILL reset on rebuild" }
        if let teamID { return "Team \(teamID) — stable across rebuilds" }
        return "Signed, but no Team ID — permissions may reset"
    }

    /// Short CDHash for display; the full hash is 40 hex characters.
    var shortHash: String {
        guard let cdHash else { return "unknown" }
        return String(cdHash.prefix(12))
    }

    static func current() -> SigningInfo {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code
        else { return .unknown }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return .unknown }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return .unknown }

        // `kSecCodeSignatureAdhoc` is declared in <Security/CSCommon.h> but is not
        // exposed to Swift, so the value is inlined:
        //     kSecCodeSignatureAdhoc = 0x0002  /* must be used without signer */
        let adhocFlag: UInt32 = 0x0002
        let signatureFlags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let adhoc = (signatureFlags & adhocFlag) != 0

        let hash = (dict[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }
            .joined()

        return SigningInfo(
            identifier: dict[kSecCodeInfoIdentifier as String] as? String,
            teamID: dict[kSecCodeInfoTeamIdentifier as String] as? String,
            cdHash: hash,
            isAdHoc: adhoc
        )
    }
}
