import SwiftUI

/// The clean-up providers.
///
/// **One rule: nothing changes the active provider except a button that says so.** The
/// previous version made tapping a row to look at it the same action as putting it into
/// service, so adding a key to a second endpoint took the working one out of use — and
/// because verification was a single global flag, coming back meant testing again.
///
/// Everything a provider knows now lives with that provider: endpoint, model and whether
/// it has been proved. Editing one leaves the other alone.
struct CleanupPane: View {

    @Bindable var settings: SettingsStore
    let dictation: DictationCoordinator

    /// Which row has its editor open. Independent of which provider is active, which is
    /// the whole point.
    @State private var editing: String?

    private var providers: ProviderStore { dictation.providers }

    var body: some View {
        PaneScroll(title: "AI clean-up") {
            SettingRow(title: "Clean up my dictation") {
                Toggle("", isOn: $settings.cleanupEnabled).labelsHidden()
            }

            if settings.cleanupEnabled {
                SectionLabel(title: "In use")
                row(providers.activeEntry, isActive: true)

                if !providers.others.isEmpty {
                    SectionLabel(title: "Other providers")
                    ForEach(providers.others) { entry in
                        row(entry, isActive: false)
                    }
                }

                if !providers.isUsable(providers.activeID) {
                    WarningRow(
                        message: "\(providers.activeEntry.displayName) isn't ready, so "
                            + "dictation will insert the raw transcript."
                    )
                }
            } else {
                Text("Dictation inserts the raw transcript. No provider, no key, no network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - A provider

    private func row(_ entry: ProviderCatalog.Entry, isActive: Bool) -> some View {
        let isOpen = editing == entry.id
        return Card(highlighted: isActive) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Monogram(name: entry.displayName)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName).font(.callout.weight(.semibold))
                        Text(providers.state(for: entry.id).model.isEmpty
                             ? "No model set"
                             : providers.state(for: entry.id).model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    badge(for: entry.id)
                    Spacer(minLength: 0)

                    // Never activates. Opening the editor for a provider you are not
                    // using is exactly the case the old pane made impossible.
                    Button(isOpen ? "Done" : (isActive ? "Edit" : "Set up")) {
                        editing = isOpen ? nil : entry.id
                    }
                    .controlSize(.small)

                    if !isActive {
                        Button("Use") { dictation.activateProvider(entry.id) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(!providers.isUsable(entry.id))
                            .help(providers.isUsable(entry.id)
                                  ? "Use this provider for clean-up"
                                  : "Add a key and a model first")
                    }
                }

                if isOpen { editor(entry) }
            }
        }
    }

    /// Three states, not two. Having a key is progress, and it used to look identical to
    /// having none.
    @ViewBuilder
    private func badge(for id: String) -> some View {
        if dictation.testingProviderID == id {
            StatusChip(title: "Testing", level: .waiting)
        } else {
            switch providers.state(for: id).verification {
            case .working(let latency, _):
                StatusChip(
                    title: "Working · \(String(format: "%.1fs", latency))", level: .ok
                )
            case .failed:
                StatusChip(title: "Not working", level: .bad)
            case .untested:
                if providers.isUsable(id) {
                    StatusChip(title: "Not tested", level: .waiting)
                } else {
                    StatusChip(
                        title: ProviderCatalog.entry(id: id).requiresKey && !providers.hasKey(id)
                            ? "No key" : "Not set up",
                        level: .bad
                    )
                }
            }
        }
    }

    // MARK: - Editor

    /// Expands in place, and holds *everything* about this provider. The model used to sit
    /// outside at one click while the key needed two, which put two equally important
    /// fields at different depths.
    private func editor(_ entry: ProviderCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if entry.requiresCustomBaseURL {
                LabeledContent("Endpoint") {
                    TextField("https://…", text: binding(\.baseURL, for: entry.id))
                        .textFieldStyle(.roundedBorder)
                }
                .font(.caption)
            }

            LabeledContent("Model") {
                TextField("Model name", text: binding(\.model, for: entry.id))
                    .textFieldStyle(.roundedBorder)
            }
            .font(.caption)

            if !entry.suggestedModels.isEmpty {
                WrapChips(items: entry.suggestedModels) { _ in }
                    .opacity(0.9)
            }

            APIKeyField(entry: entry, dictation: dictation)

            if case .failed(let reason) = providers.state(for: entry.id).verification {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Test") { dictation.testProvider(entry.id) }
                    .controlSize(.small)
                    .disabled(
                        !providers.isUsable(entry.id) || dictation.testingProviderID != nil
                    )

                if let url = entry.keyURL, let link = URL(string: url) {
                    Link("Get a key", destination: link).font(.caption)
                }

                Spacer(minLength: 0)

                Button("Reset") { providers.resetToDefaults(entry.id) }
                    .controlSize(.small)
                    .help("Put the endpoint and model back to their defaults")
            }
        }
    }

    /// Writes through the store, which resets verification — a "working" badge earned
    /// against a different endpoint would be a claim about something no longer configured.
    private func binding(
        _ field: KeyPath<ProviderStore.State, String>, for id: String
    ) -> Binding<String> {
        Binding(
            get: { providers.state(for: id)[keyPath: field] },
            set: { value in
                if field == \ProviderStore.State.baseURL {
                    providers.update(baseURL: value, for: id)
                } else {
                    providers.update(model: value, for: id)
                }
            }
        )
    }
}

/// The key for one provider, and a button that proves it.
private struct APIKeyField: View {

    let entry: ProviderCatalog.Entry
    let dictation: DictationCoordinator

    @State private var entered = ""
    @State private var saveError: String?

    private var providers: ProviderStore { dictation.providers }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(placeholder, text: $entered)
                    .textFieldStyle(.roundedBorder)

                Button("Save") { save() }
                    .controlSize(.small)
                    .disabled(entered.trimmingCharacters(in: .whitespaces).isEmpty)

                if providers.hasKey(entry.id) {
                    Button("Remove") { remove() }
                        .controlSize(.small)
                }
            }
            if let saveError {
                Text(saveError).font(.caption).foregroundStyle(.orange)
            }
            if !entry.requiresKey {
                Text("Optional — a model served on this machine doesn't need one.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholder: String {
        providers.hasKey(entry.id) ? "Stored in the Keychain" : "Paste your key"
    }

    private func save() {
        do {
            try providers.saveKey(
                entered.trimmingCharacters(in: .whitespaces), for: entry.id
            )
            entered = ""
            saveError = nil
            // A saved key says nothing about whether it works, so prove it now rather
            // than leaving a row that looks configured and has never been exercised.
            dictation.testProvider(entry.id)
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func remove() {
        try? providers.deleteKey(for: entry.id)
    }
}
