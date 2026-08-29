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
///
/// System Audio Recording (meetings mode) arrives in v2.
@MainActor
@Observable
final class PermissionManager {

    private(set) var microphone: PermissionState = .notDetermined
    private(set) var accessibility: PermissionState = .denied

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
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value
        )
        openAccessibilitySettings()
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
        NSWorkspace.shared.open(url)
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
