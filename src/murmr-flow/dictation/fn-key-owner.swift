import Darwin
import Foundation

/// Keeps macOS's own use of the fn key out of the way while fn is one of ours.
///
/// A lone fn is the system's 🌐 key: by default it switches the input source, or opens the
/// emoji picker, and a *held* fn brings up the input-source list — and while it does, the
/// system takes the modifier back. Seen in the logs as four dictations of 68–152 ms each:
/// fn went down, the system reclaimed it about a tenth of a second later, and every hold
/// became a tap. WindowServer runs that action ahead of every event tap, so a listener
/// cannot swallow it; the only way to have fn is for the system's setting to be "Do
/// Nothing" — which is what Wispr Flow asks its users to set by hand, and what OpenWhispr
/// sets for them.
///
/// `TISUpdateFnUsageType` is the call System Settings itself makes: it persists the
/// preference *and* broadcasts it, so it applies at once. Writing `AppleFnUsageType`
/// straight into the HIToolbox defaults is ignored until the next login. Both entry
/// points are private Carbon symbols, looked up at runtime and treated as optional — on a
/// macOS that no longer has them the warning in Settings takes over and the user does it.
///
/// The value found is remembered in our own defaults so it can be put back when fn stops
/// being ours or the app quits. If the user picks a new action while we own the key,
/// theirs wins: the marker is dropped and nothing is restored over it.
enum FnKeyOwner {

    /// `AppleFnUsageType`: 0 nothing, 1 change input source, 2 emoji, 3 dictation.
    static let doNothing: Int32 = 0

    /// How the system's setting is read and written. Swapped out in tests.
    struct Backend: Sendable {
        let get: @Sendable () -> Int32
        let set: @Sendable (Int32) -> Void

        static let system: Backend? = {
            typealias Get = @convention(c) () -> Int32
            typealias Update = @convention(c) (Int32) -> Void
            guard let carbon = dlopen(
                    "/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY
                  ),
                  let get = dlsym(carbon, "TISGetFnUsageType"),
                  let update = dlsym(carbon, "TISUpdateFnUsageType")
            else { return nil }
            let getFn = unsafeBitCast(get, to: Get.self)
            let updateFn = unsafeBitCast(update, to: Update.self)
            return Backend(get: { getFn() }, set: { updateFn($0) })
        }()
    }

    private enum Key {
        /// The system's value before we changed it. Present only while the key is ours.
        static let original = "fnKey.originalUsage"
    }

    /// What a lone fn does right now, or nil when the system cannot be asked.
    static func systemUsage(backend: Backend? = .system) -> Int32? {
        backend?.get()
    }

    /// Owns fn if any of these hotkeys needs it, and lets go otherwise.
    static func update(
        for hotkeys: [Hotkey?],
        defaults: UserDefaults = .standard,
        backend: Backend? = .system
    ) {
        if hotkeys.contains(where: { $0?.usesFn == true }) {
            claim(defaults: defaults, backend: backend)
        } else {
            release(defaults: defaults, backend: backend)
        }
    }

    static func claim(defaults: UserDefaults = .standard, backend: Backend? = .system) {
        guard let backend else { return }
        let current = backend.get()

        if defaults.object(forKey: Key.original) != nil {
            // Ours from an earlier run — unless the user has since chosen a new action,
            // in which case it stopped being ours and the marker is stale.
            if current != doNothing { defaults.removeObject(forKey: Key.original) }
            return
        }
        // Already off: nothing to take, nothing to give back.
        guard current != doNothing else { return }

        defaults.set(Int(current), forKey: Key.original)
        backend.set(doNothing)
    }

    static func release(defaults: UserDefaults = .standard, backend: Backend? = .system) {
        guard let original = defaults.object(forKey: Key.original) as? Int else { return }
        defaults.removeObject(forKey: Key.original)
        // Only put it back while it is still ours.
        if let backend, backend.get() == doNothing {
            backend.set(Int32(original))
        }
    }
}
