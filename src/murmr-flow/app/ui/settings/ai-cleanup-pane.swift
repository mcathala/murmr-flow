import SwiftUI

/// Clean-up: whether it runs, what runs it, and what it is told to do.
///
/// One section, because these are one subject. The provider, its key and its model used
/// to sit here while the prompts sat in a sidebar row of their own — so "why did my
/// dictation come out like this" could not be answered from either. The instructions now
/// live beside the engine that follows them.
///
/// The section is named for the job; the cards inside keep the engine's name. **AI
/// provider** is still what Home's status chip reports and what the panel names when a
/// clean-up fails, because that is a claim about the machine, not about the job.
///
/// Three groups, and **tabs rather than three headings in one scroll.** Merging the prompts
/// in gave this section eight cards, two of which open into editors, under `SectionLabel`s
/// that are 9.5pt uppercase in the faintest colour in the palette — a hint, not a division.
/// One tab at a time is a comfortable screen. It is the only section with a tab bar; see
/// `PaneTabs` for when that is the right call.
///
/// **The switches sit above the tabs, not inside one**, because they govern all three. So
/// does the not-ready warning: a provider with no key breaks prompts and spelling too, and
/// hiding that behind whichever tab happens not to be showing would be the one failure this
/// pane must never keep quiet about.
///
/// **One rule for the providers: nothing changes the active one except a button that says
/// so.** The previous version made tapping a row to look at it the same action as putting
/// it into service, so adding a key to a second endpoint took the working one out of use —
/// and because verification was a single global flag, coming back meant testing again.
///
/// Everything a provider knows now lives with that provider: endpoint, model and whether
/// it has been proved. Editing one leaves the other alone.
struct AICleanupPane: View {

    @Bindable var settings: SettingsStore
    let dictation: DictationCoordinator
    let prompts: PromptStore

    /// Which row has its editor open. Independent of which provider is active, which is
    /// the whole point.
    @State private var editing: String?

    /// Deliberately not remembered across visits. Landing on the provider every time is
    /// predictable; coming back to whichever tab you left three days ago is not.
    @State private var facet: Facet = .provider

    private var providers: ProviderStore { dictation.providers }

    /// The three groups. Named `Facet` rather than `Group` or `Tab`, both of which are
    /// SwiftUI's.
    private enum Facet: String, CaseIterable, Identifiable {
        case provider, prompts, spelling

        var id: String { rawValue }

        /// One word each, so the bar stays a bar. "Spelling" is the card called "Words to
        /// spell my way", which is too long to be a tab.
        var title: String {
            switch self {
            case .provider: "Provider"
            case .prompts: "Prompts"
            case .spelling: "Spelling"
            }
        }
    }

    var body: some View {
        PaneScroll(title: "AI clean-up") {
            SettingRow(title: "Clean up my dictation") {
                Toggle("", isOn: $settings.cleanupEnabled).labelsHidden()
            }

            SettingRow(title: "Clean up meeting notes") {
                Toggle("", isOn: $settings.notetakerCleanupEnabled).labelsHidden()
            }

            // Everything below is worth setting up if *either* switch is on, and does
            // nothing at all if neither is: the provider is shared, and so are the
            // prompts and the custom words — both are read only while rendering a
            // clean-up prompt. With clean-up off they would be controls for a stage that
            // never runs, so there is no tab bar either.
            if settings.cleanupEnabled || settings.notetakerCleanupEnabled {
                if !providers.isUsable(providers.activeID) {
                    WarningRow(
                        message: "\(providers.activeEntry.displayName) isn't ready, so "
                            + "\(Self.affected(settings)) will keep the raw transcript."
                    )
                }

                PaneTabs(tabs: Facet.allCases, title: \.title, selection: $facet)

                switch facet {
                case .provider:
                    SectionLabel(title: "In use")
                    row(providers.activeEntry, isActive: true)

                    if !providers.others.isEmpty {
                        SectionLabel(title: "Other providers")
                        ForEach(providers.others) { entry in
                            row(entry, isActive: false)
                        }
                    }
                case .prompts:
                    PromptsSection(prompts: prompts)
                case .spelling:
                    CustomWordsCard(settings: settings)
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
        switch (settings.cleanupEnabled, settings.notetakerCleanupEnabled) {
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

/// Names and jargon, as a list rather than a comma-separated text field.
///
/// These go into the **clean-up prompt**, not the speech model. The card used to sit in
/// the speech pane above a line claiming the opposite — that it biased transcription and
/// "works with clean-up switched off entirely." It never did: the words are stored under
/// `cleanup.customWords` and read in exactly one place, `PromptLibrary.render`, which
/// turns them into "Spell these correctly if you hear them: …" for the provider. With
/// clean-up off they did nothing at all, which is why the card now sits inside the branch
/// that only draws when one of the two switches is on.
///
/// Biasing the speech model itself would be the better fix and is a different job — it
/// needs vocabulary support from FluidAudio, not a prompt.
private struct CustomWordsCard: View {

    @Bindable var settings: SettingsStore
    @State private var entry = ""

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if settings.customWords.isEmpty {
                    Text("Names the clean-up should spell your way, however they come "
                         + "out of the speech model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    RemovableChips(items: settings.customWords) { word in
                        settings.customWords.removeAll { $0 == word }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Add a word", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .controlSize(.small)
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let word = entry.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !settings.customWords.contains(word) else { return }
        settings.customWords.append(word)
        entry = ""
    }
}
