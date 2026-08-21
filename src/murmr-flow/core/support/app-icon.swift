import AppKit

/// Real application icons, looked up by bundle identifier.
///
/// Worth distinguishing from the provider monograms elsewhere: those stand in for *other
/// companies'* brand marks, which would mean shipping and maintaining trademarked assets.
/// These are apps already installed on this Mac, and macOS hands over the icon on request
/// — nothing to ship, and always the current version of it.
///
/// Cached because a list redraws far more often than an app's icon changes, and each miss
/// is a disk lookup.
@MainActor
enum AppIconCache {

    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        // The dictionary stores the *optional*, so a lookup that found nothing is
        // remembered too rather than being retried on every redraw.
        if let cached = cache[bundleID] { return cached }

        let resolved = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }

        cache[bundleID] = resolved
        return resolved
    }
}
