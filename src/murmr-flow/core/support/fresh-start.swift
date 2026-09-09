import Foundation
import OSLog

/// `--fresh`: start as a machine that has never run Murmr Flow.
///
/// For testing the first launch. Everything the app remembers about itself goes — every
/// default, including onboarding's completion and the remembered system-audio probe, and
/// every API key in the Keychain — so the next screen is the first onboarding page with
/// nothing filled in. The person's own work stays: notes are files in Documents and the
/// dictation history is its own log, and neither is ours to throw away on a flag.
/// `scripts/dev.sh --wipe-data` removes those separately, on purpose.
///
/// Runs before anything reads a default, which is why the App's `init` calls it rather
/// than `AppServices.start`: every store loads its values the moment it is made.
///
/// The permission grants are not the app's to reset — `tccutil` is — so the script does
/// that half. Without it, a fresh start on a signed build would skip the permission pages,
/// because the grants would still hold.
enum FreshStart {

    static let argument = "--fresh"

    private static let log = Logger(subsystem: "app.murmr.MurmrFlow", category: "fresh-start")

    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    static func applyIfRequested() {
        guard isRequested, let bundleID = Bundle.main.bundleIdentifier else { return }

        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        for entry in ProviderCatalog.all {
            try? KeychainStore.delete(account: KeychainStore.account(forProvider: entry.id))
        }

        log.notice("fresh start: defaults and keys cleared")
    }
}
