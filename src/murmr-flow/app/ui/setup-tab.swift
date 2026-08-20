import SwiftUI

/// Everything you configure once: permissions, the speech model, the hotkey.
///
/// Permissions collapse to a single line once granted. They were taking 352 pt
/// permanently to say "two things are fine", which is setup-time information occupying
/// daily space.
struct SetupTab: View {

    let permissions: PermissionManager
    @Bindable var dictation: DictationCoordinator

    @State private var showSigning = false
    @State private var showPermissionDetail = false

    var body: some View {
        TabScroll {
            permissionsSection
            Divider()
            modelSection
            Divider()
            hotkeySection
            Divider()
            signingSection
        }
        .onAppear { permissions.refresh() }
    }

    // MARK: - Permissions

    @ViewBuilder
    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Permissions", icon: "lock.shield")

            if permissions.allGranted {
                DisclosureGroup(isExpanded: $showPermissionDetail) {
                    VStack(alignment: .leading, spacing: 10) {
                        microphoneRow
                        accessibilityRow
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Microphone and Accessibility granted")
                            .font(.caption)
                    }
                }
                .font(.caption2)
            } else {
                microphoneRow
                accessibilityRow
            }
        }
    }

    private var microphoneRow: some View {
        PermissionRow(
            title: "Microphone",
            state: permissions.microphone,
            explanation: "Without this, dictation can't hear you."
        ) {
            switch permissions.microphone {
            case .notDetermined:
                Button("Allow…") { Task { await permissions.requestMicrophone() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            case .denied:
                Button("Open Settings") { permissions.openMicrophoneSettings() }
                    .controlSize(.small)
            case .granted:
                EmptyView()
            }
        }
    }

    private var accessibilityRow: some View {
        PermissionRow(
            title: "Accessibility",
            state: permissions.accessibility,
            explanation: "Without this, dictation copies to the clipboard instead of typing."
        ) {
            if permissions.accessibility != .granted {
                HStack(spacing: 6) {
                    Button("Open Settings") { permissions.openAccessibilitySettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Ask macOS") { permissions.promptAccessibility() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Speech model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Speech to text", icon: "waveform")

            Picker("", selection: Binding(
                get: { dictation.settings.speechModel },
                set: { dictation.changeSpeechModel($0) }
            )) {
                ForEach(SpeechModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(dictation.models.state.isBusy || dictation.stage.isBusy)

            Text(dictation.settings.speechModel.summary)
                .font(.caption2)
                .foregroundStyle(.secondary)

            modelStateRow

            DisclosureGroup("Languages covered") {
                Text(dictation.settings.speechModel.languages.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .font(.caption2)
        }
    }

    @ViewBuilder
    private var modelStateRow: some View {
        switch dictation.models.state {
        case .notLoaded:
            HStack(spacing: 8) {
                let downloaded = dictation.models.isSelectedDownloaded
                Text(downloaded
                     ? "Already downloaded"
                     : "~\(dictation.settings.speechModel.approximateSizeMB) MB download")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(downloaded ? "Load" : "Download & load") {
                    Task { await dictation.warmUp() }
                }
                .controlSize(.small)
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption2).foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                Text("Downloading… \(Int(fraction * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption2).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Ready on the Neural Engine").font(.caption2)
            }
        case .failed(let message):
            WarningRow(message: message)
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Push to talk", icon: "keyboard")

            Picker("", selection: Binding(
                get: { dictation.settings.hotkey },
                set: { dictation.changeHotkey(to: $0) }
            )) {
                ForEach(HotkeyMonitor.Trigger.allCases) { trigger in
                    Text(trigger.displayName).tag(trigger)
                }
            }
            .labelsHidden()
            .disabled(dictation.stage.isBusy)

            Text("A modifier key is used so holding it while speaking can't collide with "
                 + "typing. The keypress still reaches whatever app you're in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Pause music while dictating", isOn: Binding(
                get: { dictation.settings.pauseMediaWhileDictating },
                set: { dictation.settings.pauseMediaWhileDictating = $0 }
            ))
            .font(.caption)
            .controlSize(.small)

            Text("Only pauses if something is actually playing, and only resumes what it "
                 + "paused.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Signing diagnostics

    /// Kept, but out of the way. This is the first thing worth checking if permissions
    /// ever start resetting, and it is otherwise irrelevant.
    private var signingSection: some View {
        DisclosureGroup(isExpanded: $showSigning) {
            SigningDetails().padding(.top, 6)
        } label: {
            SectionLabel(title: "Code signature", icon: "signature")
        }
        .font(.caption2)
    }
}

/// One permission: status, the symptom if it's missing, and its action.
struct PermissionRow<Action: View>: View {

    let title: String
    let state: PermissionState
    let explanation: String
    @ViewBuilder let action: Action

    private var tint: Color {
        switch state {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(state.label).font(.caption2).foregroundStyle(.secondary)
                }
                if state != .granted {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)
            action
        }
    }
}

/// Reads the running app's own signature. Whether permissions survive a rebuild depends
/// on the Team ID staying stable while the CDHash changes.
struct SigningDetails: View {

    private let signing = SigningInfo.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: signing.isStableForTCC
                      ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(signing.isStableForTCC ? .green : .orange)
                Text(signing.summary)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DetailGrid {
                GridRow {
                    Text("Identifier").foregroundStyle(.secondary)
                    Text(signing.identifier ?? "unknown")
                }
                GridRow {
                    Text("CDHash").foregroundStyle(.secondary)
                    Text(signing.shortHash).monospaced()
                }
            }

            if !signing.isStableForTCC {
                Text("Ad-hoc signatures have no Team ID, so macOS identifies this app by "
                     + "its CDHash and will forget permissions on the next build. Run "
                     + "scripts/make-cert.sh.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
