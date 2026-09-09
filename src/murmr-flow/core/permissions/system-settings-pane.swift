import Foundation

/// The one place the system-audio pane is named.
///
/// Copy called it "System Audio Recording", the button opened "Screen & System Audio
/// Recording", and a third deep link pointed at a pane that does not hold the toggle at
/// all. Three names for one switch is how a person ends up in the wrong place with the
/// right intention. Whatever macOS renames it to next, it changes here once.
enum SystemSettingsPane {
    /// What the pane is called in System Settings › Privacy & Security.
    static let systemAudio = "Screen & System Audio Recording"

    /// The deep link that opens it. The audio-only grant shares the screen-capture pane.
    static let systemAudioURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
}
