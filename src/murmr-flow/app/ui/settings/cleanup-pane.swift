import SwiftUI

/// One active provider, a list of the rest, and a verification state on every one.
///
/// "Not tested" is the honest default. A key that was pasted is not a key that works, and
/// until now the difference only ever surfaced as a failed dictation.
struct CleanupPane: View {

    @Bindable var settings: SettingsStore
    let dictation: DictationCoordinator

    @State private var isEditing = false

    var body: some View {
        PaneScroll(title: "AI clean-up") {
            SettingRow(title: "Clean up my dictation") {
                Toggle("", isOn: $settings.cleanupEnabled).labelsHidden()
            }

            if settings.cleanupEnabled {
                SectionLabel(title: "Active")
                activeProvider

                SectionLabel(title: "Other providers")
                ForEach(others) { entry in
                    providerRow(entry)
                }
            } else {
                Text("Dictation inserts the raw transcript. No provider, no key, no network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var others: [ProviderCatalog.Entry] {
        ProviderCatalog.all.filter { $0.id != settings.providerID }
    }

    // MARK: - Active

    private var activeProvider: some View {
        Card(highlighted: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Monogram(name: settings.providerEntry.displayName)
                    Text(settings.providerEntry.displayName).font(.callout.weight(.semibold))
                    verification
                    Spacer(minLength: 0)
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                        .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Text("Model").font(.caption).foregroundStyle(.secondary)
                    TextField("Model", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(maxWidth: 260)
                }

                if isEditing { editor }
            }
        }
    }

    @ViewBuilder
    private var verification: some View {
        switch dictation.providerTest {
        case .idle:
            StatusChip(title: settings.hasAPIKey ? "Not tested" : "No key", level: .bad)
        case .running:
            StatusChip(title: "Testing", level: .waiting)
        case .working(let latency):
            StatusChip(
                title: "Working · \(String(format: "%.1fs", latency))", level: .ok
            )
        case .failed:
            StatusChip(title: "Not working", level: .bad)
        }
    }

    /// Expands in place rather than opening a sheet, so you can see which provider you
    /// are editing while you edit it.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if settings.providerEntry.requiresCustomBaseURL {
                LabeledContent("Endpoint") {
                    TextField("https://…", text: $settings.baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)
            }

            APIKeyField(settings: settings, dictation: dictation)

            if case .failed(let message) = dictation.providerTest {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Picker("Provider", selection: $settings.providerID) {
                    ForEach(ProviderCatalog.all) { entry in
                        Text(entry.displayName).tag(entry.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                if let url = settings.providerEntry.keyURL, let link = URL(string: url) {
                    Link("Get a key", destination: link).font(.caption)
                }
            }
        }
    }

    // MARK: - Others

    private func providerRow(_ entry: ProviderCatalog.Entry) -> some View {
        Button {
            settings.providerID = entry.id
            dictation.resetProviderTest()
            isEditing = true
        } label: {
            Card {
                HStack(spacing: 10) {
                    Monogram(name: entry.displayName)
                    Text(entry.displayName).font(.callout)
                    StatusChip(
                        title: KeychainStore.hasKey(
                            account: KeychainStore.account(forProvider: entry.id)
                        ) ? "Not tested" : "No key",
                        level: .bad
                    )
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// The key, and a button that proves it.
private struct APIKeyField: View {

    @Bindable var settings: SettingsStore
    let dictation: DictationCoordinator

    @State private var entry = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(
                    settings.hasAPIKey ? "Stored in the Keychain" : "Paste your key",
                    text: $entry
                )
                .textFieldStyle(.roundedBorder)

                Button("Save") { save() }
                    .controlSize(.small)
                    .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("Test") { dictation.testProvider() }
                    .controlSize(.small)
                    .disabled(!settings.hasAPIKey || dictation.providerTest == .running)

                if settings.hasAPIKey {
                    Button("Remove") { remove() }
                        .controlSize(.small)
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        do {
            try settings.saveAPIKey(entry.trimmingCharacters(in: .whitespaces))
            entry = ""
            saveError = nil
            // Saving a key says nothing about whether it works, so prove it immediately
            // rather than leaving a green-looking row that has never been exercised.
            dictation.testProvider()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func remove() {
        try? settings.deleteAPIKey()
        dictation.resetProviderTest()
    }
}
