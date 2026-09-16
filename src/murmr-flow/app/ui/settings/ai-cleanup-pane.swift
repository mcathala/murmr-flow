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
/// does the not-ready warning: a provider with no key breaks the prompts and the dictionary
/// hints too, and hiding that behind whichever tab happens not to be showing would be the
/// one failure this pane must never keep quiet about.
///
/// **The tab bar is not gated, though the tabs are.** Everything here used to collapse to
/// one sentence with both switches off, which was right while everything here needed a
/// provider. The dictionary's exact replacements do not — they are local string work — so
/// hiding that tab would hide a feature that still works. Provider says it is off; Styles
/// still lists the styles, dimmed, so two tabs never show one identical sentence.
///
/// **One rule for the providers: nothing changes the active one except a button that says
/// so.** The previous version made tapping a row to look at it the same action as putting
/// it into service, so adding a key to a second endpoint took the working one out of use —
/// and because verification was a single global flag, coming back meant testing again.
///
/// **And one rule for testing: there is no Test button.** Every change that could alter
/// the answer — a key saved, a model picked, an endpoint typed — runs the test itself, so
/// the badge is always a claim about what is configured now. The one manual test left is
/// the badge when it reads "Not working": for a network that blinked, not for a change.
///
/// Everything a provider knows now lives with that provider: endpoint, model and whether
/// it has been proved. Editing one leaves the other alone.
struct AICleanupPane: View {

    let services: AppServices

    private var settings: SettingsStore { services.settings }
    private var dictation: DictationCoordinator { services.dictation }
    private var prompts: PromptStore { services.prompts }
    private var dictionary: DictionaryStore { services.dictionary }

    /// Which row has its editor open. Independent of which provider is active, which is
    /// the whole point.
    @State private var editing: String?

    /// Deliberately not remembered across visits. Landing on the provider every time is
    /// predictable; coming back to whichever tab you left three days ago is not.
    @State private var facet: Facet = .provider

    /// Which text field has the keyboard, so leaving one can run the test the way
    /// pressing Return does. Typing does not: a test per keystroke would be a request per
    /// keystroke.
    @FocusState private var focused: Field?

    /// Providers whose endpoint or model changed since their last test. Leaving the field
    /// tests these and only these; tabbing through an untouched field runs nothing.
    @State private var dirty: Set<String> = []

    /// The key about to be removed, so the row can ask first. Notes ask; a key that took a
    /// trip to a console to get deserves the same.
    @State private var removingKeyFor: String?

    private var providers: ProviderStore { dictation.providers }

    private enum Field: Hashable {
        case baseURL(String), model(String)

        var providerID: String {
            switch self {
            case .baseURL(let id), .model(let id): id
            }
        }
    }

    /// The three groups. Named `Facet` rather than `Group` or `Tab`, both of which are
    /// SwiftUI's.
    private enum Facet: String, CaseIterable, Identifiable {
        case provider, prompts, dictionary

        var id: String { rawValue }

        /// One word each, so the bar stays a bar.
        var title: String {
            switch self {
            case .provider: "Provider"
            // "Styles" to the user — onboarding and the pill both taught that word; the
            // things being styles is how they are chosen, prompts is how they are made.
            case .prompts: "Styles"
            case .dictionary: "Dictionary"
            }
        }
    }

    /// Whether anything is cleaned at all. The provider is shared, so one switch is enough
    /// to make setting it up worthwhile.
    private var isCleaningSomething: Bool {
        settings.cleanupEnabled || settings.notetakerCleanupEnabled
    }

    /// The one switch, which moves both jobs together.
    ///
    /// The two were separate controls because the trade differs — dictation clean-up costs
    /// seconds before text appears, a meeting is already over — but two switches for one
    /// question was a header row nobody read twice, and the store keeps both so an install
    /// that had only one of them on stays that way until this is touched.
    private var cleanupOn: Binding<Bool> {
        Binding(
            get: { isCleaningSomething },
            set: { on in
                settings.cleanupEnabled = on
                settings.notetakerCleanupEnabled = on
            }
        )
    }

    var body: some View {
        PaneScroll(title: "AI clean-up") {
            if isCleaningSomething, !providers.isUsable(providers.activeID) {
                WarningRow(
                    message: "\(providers.activeEntry.displayName) isn't ready, so "
                        + "\(Self.affected(settings)) will keep the raw transcript.",
                    // The fix is on this very pane, one tab over — walk there rather
                    // than describing the walk.
                    action: ("Set up", { facet = .provider })
                )
            }

            PaneTabs(tabs: Facet.allCases, title: \.title, selection: $facet)

            switch facet {
            case .provider:
                if isCleaningSomething {
                    SectionLabel(title: "In use")
                    row(providers.activeEntry, isActive: true)

                    if !providers.others.isEmpty {
                        SectionLabel(title: "Other providers")
                        ForEach(providers.others) { entry in
                            row(entry, isActive: false)
                        }
                    }
                } else {
                    switchedOff
                }
            case .prompts:
                if isCleaningSomething {
                    styles
                } else {
                    // The list stays, dimmed: what the styles are is worth seeing before
                    // deciding to switch clean-up on. Editing them can wait until it is.
                    switchedOff
                    styles
                        .opacity(0.45)
                        .disabled(true)
                }
            case .dictionary:
                DictionarySection(dictionary: dictionary, cleanupIsOn: isCleaningSomething)
            }
        }
        .onChange(of: focused) { before, _ in
            // Leaving a field is the commit, the same as Return. Only a field that was
            // actually edited runs the test.
            guard let before, dirty.contains(before.providerID) else { return }
            retest(before.providerID)
        }
        .confirmationDialog(
            "Remove this key?",
            isPresented: Binding(
                get: { removingKeyFor != nil }, set: { if !$0 { removingKeyFor = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let id = removingKeyFor { try? providers.deleteKey(for: id) }
                removingKeyFor = nil
            }
            Button("Cancel", role: .cancel) { removingKeyFor = nil }
        } message: {
            Text("Clean-up through this provider stops until a key is added again.")
        }
    }

    /// The styles themselves, then which app gets which. One list makes the other
    /// readable: a rule naming a style you cannot see above it would be a setting with its
    /// subject somewhere else.
    @ViewBuilder
    private var styles: some View {
        PromptsSection(
            prompts: prompts,
            bindKey: { key, styleID in services.changeStyleHotkey(key, for: styleID) }
        )
        AppStylesSection(prompts: prompts)
    }

    private var switchedOff: some View {
        Text("Dictation and Notetaker both keep the raw transcript. No provider, no key, "
             + "no network. The switch is on the provider, under Provider.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Names only what is actually switched on, so the warning can't claim dictation is
    /// affected when only notes are.
    private static func affected(_ settings: SettingsStore) -> String {
        switch (settings.cleanupEnabled, settings.notetakerCleanupEnabled) {
        case (true, true): "dictation and Notetaker"
        case (true, false): "dictation"
        default: "Notetaker"
        }
    }

    // MARK: - A provider

    private func row(_ entry: ProviderCatalog.Entry, isActive: Bool) -> some View {
        let isOpen = editing == entry.id
        return Card(highlighted: isActive) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderMark(entry: entry)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.displayName).font(.callout.weight(.semibold))
                        Text(subtitle(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    ProviderBadge(id: entry.id, providers: providers, dictation: dictation)
                    Spacer(minLength: 0)

                    // Never activates. Opening the editor for a provider you are not
                    // using is exactly the case the old pane made impossible.
                    Button(isOpen ? "Done" : (isActive ? "Edit" : "Set up")) {
                        toggle(entry.id)
                    }
                    .controlSize(.small)

                    if isActive {
                        // Clean-up on or off, on the row that says which provider would
                        // do it. It was a header row of its own above the tabs, which put
                        // the switch one subject away from the thing it switches — and
                        // made the first row of the pane something nobody needed twice.
                        Toggle("", isOn: cleanupOn)
                            .labelsHidden()
                            .help(isCleaningSomething
                                  ? "Turn clean-up off — dictations and notes keep the raw transcript"
                                  : "Clean up dictations and notes through this provider")
                            .accessibilityLabel("AI clean-up")
                    } else {
                        Button("Use") { dictation.activateProvider(entry.id) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(!providers.isUsable(entry.id))
                            .help(providers.isUsable(entry.id)
                                  ? "Use this provider for clean-up"
                                  : "Add a key and a model first")
                    }
                }
                // The whole header opens the editor, the same gesture as a style row:
                // the row is the thing you want to open, and a 40-point target at its far
                // end is not. The buttons are buttons, so their taps never reach this.
                .contentShape(Rectangle())
                .onTapGesture { toggle(entry.id) }

                if isOpen { editor(entry) }
            }
        }
    }

    private func toggle(_ id: String) {
        editing = editing == id ? nil : id
    }

    /// The model in use, or what the row is for when nothing is set yet. Custom says
    /// what kind of server it takes, since its name no longer does.
    private func subtitle(for entry: ProviderCatalog.Entry) -> String {
        let model = providers.state(for: entry.id).model
        if !model.isEmpty { return model }
        return entry.requiresCustomBaseURL
            ? "Your own server: Ollama, LM Studio, vLLM…"
            : "No model set"
    }

    // MARK: - Editor

    /// Expands in place, and holds *everything* about this provider. The model used to sit
    /// outside at one click while the key needed two, which put two equally important
    /// fields at different depths.
    private func editor(_ entry: ProviderCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if entry.requiresCustomBaseURL {
                // What kind of server this takes, before the field that takes it. The
                // provider's name used to carry this as "(OpenAI-compatible)", which named
                // the protocol without saying what it meant or what happens otherwise.
                Text(ProviderCatalog.customExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Endpoint") {
                    TextField("http://…", text: binding(\.baseURL, for: entry.id))
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .baseURL(entry.id))
                        .onSubmit { retest(entry.id) }
                }
                .font(.caption)

                if !entry.suggestedEndpoints.isEmpty {
                    SuggestionChips(
                        items: entry.suggestedEndpoints,
                        current: providers.state(for: entry.id).baseURL,
                        help: "Use this address"
                    ) { url in
                        providers.update(baseURL: url, for: entry.id)
                        retest(entry.id)
                    }
                }
            }

            LabeledContent("Model") {
                TextField("Model name", text: binding(\.model, for: entry.id))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .model(entry.id))
                    .onSubmit { retest(entry.id) }
            }
            .font(.caption)

            if !entry.suggestedModels.isEmpty {
                SuggestionChips(
                    items: entry.suggestedModels,
                    current: providers.state(for: entry.id).model
                ) { model in
                    // A chip is a whole answer, so it is tested at once — there is no
                    // half-typed state to wait out.
                    providers.update(model: model, for: entry.id)
                    retest(entry.id)
                }
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
                onRemove: { removingKeyFor = entry.id }
            )

            if case .failed(let reason) = providers.state(for: entry.id).verification {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let url = entry.keyURL, let link = URL(string: url) {
                    Link("Get a key", destination: link).font(.caption)
                }

                Spacer(minLength: 0)

                Button("Reset") {
                    providers.resetToDefaults(entry.id)
                    retest(entry.id)
                }
                .controlSize(.small)
                .help("Put the endpoint and model back to their defaults")
            }
        }
    }

    /// Runs the test if there is anything to test. A provider with no key yet reads "No
    /// key" and is left alone; testing it would only produce a failure it already shows.
    private func retest(_ id: String) {
        dirty.remove(id)
        guard providers.isUsable(id) else { return }
        dictation.testProvider(id)
    }

    /// Writes through the store, which resets verification — a "working" badge earned
    /// against a different endpoint would be a claim about something no longer configured
    /// — and marks the provider for a test when the field is left.
    private func binding(
        _ field: KeyPath<ProviderStore.State, String>, for id: String
    ) -> Binding<String> {
        Binding(
            get: { providers.state(for: id)[keyPath: field] },
            set: { value in
                guard value != providers.state(for: id)[keyPath: field] else { return }
                if field == \ProviderStore.State.baseURL {
                    providers.update(baseURL: value, for: id)
                } else {
                    providers.update(model: value, for: id)
                }
                dirty.insert(id)
            }
        )
    }
}

/// What the app knows about a provider's health, in one chip.
///
/// Four states, not two. Having a key is progress, and it used to look identical to
/// having none. And "Not working" is the one chip that is also a button: the test that
/// produced it may have hit a network that blinked, and the retry belongs on the verdict
/// rather than on a Test button that would otherwise sit there for every other state too.
struct ProviderBadge: View {
    let id: String
    let providers: ProviderStore
    let dictation: DictationCoordinator

    var body: some View {
        if dictation.testingProviderID == id {
            StatusChip(title: "Testing", level: .waiting)
        } else {
            switch providers.state(for: id).verification {
            case .working(let latency, _):
                StatusChip(
                    title: "Working · \(String(format: "%.1fs", latency))", level: .ok
                )
            case .failed:
                Button { dictation.testProvider(id) } label: {
                    StatusChip(title: "Not working · Retry", level: .bad)
                }
                .buttonStyle(.plain)
                .disabled(dictation.testingProviderID != nil)
                .help("Test this provider again")
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
}
