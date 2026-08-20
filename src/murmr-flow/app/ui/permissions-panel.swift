import SwiftUI

/// The Phase 0 panel: permission status, the signing identity behind it, and the
/// gate instructions.
///
/// This grows into the Permissions section of Settings, so the copy here already
/// follows the rule of describing *the symptom the user will see* rather than the
/// technical cause.
struct PermissionsPanel: View {

    let permissions: PermissionManager

    /// Read once at launch. The CDHash is baked into the running binary, so it cannot
    /// change while the app is alive — it changes on the *next* build.
    private let signing = SigningInfo.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                microphoneRow
                accessibilityRow
            }

            Divider()

            signingPanel

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { permissions.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Murmr Flow").font(.headline)
                Text("Phase 0 — signing harness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if permissions.allGranted {
                Label("Ready", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
    }

    // MARK: - Permission rows

    private var microphoneRow: some View {
        PermissionRow(
            title: "Microphone",
            state: permissions.microphone,
            // Symptom, not cause.
            explanation: "Without this, dictation can't hear you."
        ) {
            switch permissions.microphone {
            case .notDetermined:
                Button("Allow…") {
                    Task { await permissions.requestMicrophone() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .denied:
                // macOS only ever prompts once, so after a denial the only route is
                // System Settings.
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

    // MARK: - Signing panel

    private var signingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Code signature", systemImage: "signature")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: signing.isStableForTCC
                      ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(signing.isStableForTCC ? .green : .orange)
                Text(signing.summary)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    Text("Identifier").foregroundStyle(.secondary)
                    Text(signing.identifier ?? "unknown")
                }
                GridRow {
                    Text("CDHash").foregroundStyle(.secondary)
                    Text(signing.shortHash).monospaced()
                }
            }
            .font(.caption2)

            if signing.isStableForTCC {
                Text("The CDHash changes on every build. The Team ID doesn't — that's "
                     + "why the permissions above survive a rebuild.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Ad-hoc signatures have no Team ID, so macOS identifies this app "
                     + "by its CDHash and will forget the permissions above on the "
                     + "next build. Run scripts/make-cert.sh.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Refresh") { permissions.refresh() }
                .controlSize(.small)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

/// One permission: status, the symptom if it's missing, and its action button.
private struct PermissionRow<Action: View>: View {

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
                .font(.body)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(state.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
