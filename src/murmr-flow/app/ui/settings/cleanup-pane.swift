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

            SettingRow(title: "Clean up meeting notes") {
                Toggle("", isOn: $settings.noteCleanupEnabled).labelsHidden()
            }

            // The provider is shared, so it is worth setting up if *either* is on.
            if settings.cleanupEnabled || settings.noteCleanupEnabled {
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
                            + "\(Self.affected(settings)) will keep the raw transcript."
                    )
                }
            } else {
                Text("Dictation and meeting notes both keep the raw transcript. No "
                     + "provider, no key, no network.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Names only what is actually switched on, so the warning can't claim dictation is
    /// affected when only notes are.
    private static func affected(_ settings: SettingsStore) -> String {
        switch (settings.cleanupEnabled, settings.noteCleanupEnabled) {
        case (true, true): "dictation and meeting notes"
        case (true, false): "dictation"
        default: "meeting notes"
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
                SuggestionChips(
                    items: entry.suggestedModels,
                    current: providers.state(for: entry.id).model
                ) { providers.update(model: $0, for: entry.id) }
            }

            StoredSecretRow(
                hasKey: providers.hasKey(entry.id),
                isOptional: !entry.requiresKey,
                onSave: { key in
                    try? providers.saveKey(key, for: entry.id)
                    // A saved key says nothing about whether it works, so prove it now
                    // rather than leaving a row that looks configured and never ran.
                    dictation.testProvider(entry.id)
                },
                onRemove: { try? providers.deleteKey(for: entry.id) }
            )

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
