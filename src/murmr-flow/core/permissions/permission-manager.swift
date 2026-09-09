import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// Tracks and requests the macOS permissions Murmr Flow needs.
///
/// Phase 0 covers the two that dictation requires:
///
///   - **Microphone** — has a real system prompt. One click, and only the first time.
///   - **Accessibility** — *cannot be prompted.* There is no API that grants it.
///     `AXIsProcessTrusted()` returns a bool and that is all you get, so the app must
///     deep-link to System Settings and poll for the state to flip.
///   - **System Audio Recording** (meetings) — cannot even be *read*. The only probe is
///     creating a tap, and the first attempt is also the request, so the state here is
///     what the last probe proved — see `SystemAudioRecorder.probeAccess`.
@MainActor
@Observable
final class PermissionManager {

    private(set) var microphone: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .denied
    /// Meetings only, so deliberately not part of `allGranted` — a dictation-only user
    /// should never see a warning about a grant they have no use for.
    private(set) var systemAudio: PermissionState =
        SystemAudioRecorder.hasKnownAccess ? .granted : .notDetermined

    /// True once every permission dictation needs is granted.
    var allGranted: Bool { microphone == .granted && accessibility == .granted }

    private var pollTask: Task<Void, Never>?

    init() {
        refresh()
    }

    // MARK: - Reading state

    func refresh() {
        microphone = Self.microphoneState()
        // AXIsProcessTrusted() is the only way to read this. There is no
        // "notDetermined" state — either the app is in the Accessibility list or not.
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        // Never regresses here: a probe is the only thing that can say no, and a meeting
        // succeeding says yes as a side effect.
        if SystemAudioRecorder.hasKnownAccess { systemAudio = .granted }
    }

    /// Runs the throwaway-tap probe off the main thread — the first call ever shows
    /// Apple's prompt and blocks on the answer, so it must come from a button press.
    /// After a denial it re-checks silently, which is what lets onboarding notice a grant
    /// made in System Settings.
    func requestSystemAudio() async {
        let granted = await Task.detached { SystemAudioRecorder.probeAccess() }.value
        systemAudio = granted ? .granted : .denied
    }

    func openSystemAudioSettings() {
        open(SystemSettingsPane.systemAudioURL)
    }

    private static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: - Requesting

    /// Shows the real system microphone prompt — but only the first time. Once the
    /// user has answered, macOS never asks again; they must change it in Settings.
    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Shows Apple's "would like to control this computer" dialog, which offers a
    /// button to open the right Settings pane. This grants nothing on its own — the
    /// user still has to flip the toggle themselves.
    func promptAccessibility() {
        // The SDK imports `kAXTrustedCheckOptionPrompt` inconsistently across
        // toolchains (sometimes CFString, sometimes Unmanaged<CFString>), so use the
        // documented string value directly and side-step the ambiguity.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    /// Puts the app in the Accessibility list and opens the pane — no dialog.
    ///
    /// An app is listed in that pane once TCC has been asked about it. Apple's dialog does
    /// that, but it is a whole extra screen whose only useful button opens the pane we can
    /// open ourselves. A single accessibility call asks TCC the same question quietly: it
    /// is refused, the refusal is recorded, and the app appears in the list with its
    /// toggle off — which is the state the user needs to see to flip it.
    ///
    /// `promptAccessibility()` stays as the fallback for a machine where this does not
    /// list the app; the dialog is guaranteed to.
    func requestAccessibility() {
        if dropStaleAccessibilityEntries() {
            // After a reset the quiet ask does not put the app back in the list — seen
            // once, with the row simply gone. Apple's dialog always does, so take it.
            promptAccessibility()
            openAccessibilitySettings()
            return
        }
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value
        )
        openAccessibilitySettings()
    }

    /// Ad-hoc builds only. TCC tells one build from the next by its code hash, and an
    /// ad-hoc hash changes on every build — so the Accessibility list fills with rows for
    /// builds that no longer exist, all named Murmr Flow, and the toggle the person flips
    /// belongs to one of them. That was a real afternoon lost: switched off, switched on,
    /// still "Not granted". Clearing our own bundle's entries first means the one row that
    /// appears is this build's. A signed build never has the problem and is left alone;
    /// `tccutil` needs no privileges for the calling app's own identifier.
    @discardableResult
    private func dropStaleAccessibilityEntries() -> Bool {
        guard SigningInfo.current().isAdHoc,
              let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleID]
        process.standardOutput = nil
        process.standardError = nil
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // Nothing lost: the warning row in onboarding still explains the manual way.
            return false
        }
    }

    // MARK: - Deep links

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        startPolling()
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        // System Settings activates on whatever Space it was last used on, so opening a
        // pane while it is running drags the user's whole desktop over to it — observed
        // mid-onboarding, where it read as the app switching windows by itself. Quitting
        // a running instance first makes it launch fresh on the current Space; it holds
        // no state worth preserving.
        //
        // `forceTerminate`, not `terminate`: a polite quit is delivered as an Apple
        // Event, which the hardened runtime refuses without the automation entitlement —
        // tccd logs "kTCCServiceAppleEvents requires entitlement" and nothing quits, which
        // is how the first version of this fix managed to fix nothing. The entitlement
        // would cost its own "wants to control System Settings" prompt; a plain kill costs
        // neither, and waits for the corpse before opening so the URL cannot reanimate it.
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.systempreferences"
        )
        running.forEach { _ = $0.forceTerminate() }
        Task { @MainActor in
            for _ in 0..<10 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Polling

    /// Accessibility grants emit no notification, so polling is the only way to
    /// notice one. Onboarding relies on this to advance by itself rather than making
    /// the user come back and click "Next".
    func startPolling(interval: Duration = .seconds(1)) {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.refresh()
                if self.accessibility == .granted {
                    self.stopPolling()
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
