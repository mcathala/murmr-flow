import AppKit
import SwiftUI

/// First launch, as seven screens in the main window with the sidebar out of the way.
///
/// In the window rather than a window of its own: `AppDelegate` already has to poll for
/// the main window and drag it on screen, and a second window would double every one of
/// those problems for a screen that is seen once.
///
/// The shape is the same on every step — what this is, one line on why, the thing's current
/// state, and a footer with the way past on the left and the one action on the right. The
/// action is in the footer and nowhere else, so there is never a button in the middle of
/// the screen and another at the bottom asking the same question.
///
/// **Written for someone who does not know what a model, a hotkey or a cursor is.** The
/// first draft explained each permission the way the code understands it, and a reader who
/// has never heard of Accessibility learned nothing from "macOS has no prompt for it". The
/// rule now: say what the app will be able to do for them, and what to click. The
/// technology gets its own page, once, in plain words.
struct OnboardingView: View {

    let services: AppServices

    private var onboarding: OnboardingCoordinator { services.onboarding }
    private var permissions: PermissionManager { services.permissions }
    private var dictation: DictationCoordinator { services.dictation }
    private var loader: SpeechModelLoader { services.dictation.loader }
    private var speech: SpeechModelStore { services.speech }
    private var settings: SettingsStore { services.settings }
    private var prompts: PromptStore { services.prompts }
    private var providers: ProviderStore { services.providers }
    private var step: OnboardingCoordinator.Step { onboarding.step }

    /// The languages picked on the first screen. They decide the model; the person never
    /// sees a model name.
    @State private var languages: Set<String> = []

    /// Whether the Accessibility pane has been opened once already from this step.
    @State private var askedForAccessibility = false

    /// Which key is being re-recorded from the How-it-works cards, if either.
    private enum RebindSlot { case dictation, meeting }
    @State private var rebinding: RebindSlot?
    @State private var rebindRecorder = HotkeyRecorder()
    /// Which style group's example is open. One at a time: the page has a height budget.
    @State private var previewing: String?

    /// Read once: the signature does not change while the process runs.
    private static let signing = SigningInfo.current()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Step \(onboarding.position) of \(onboarding.total)")
            Text(title)
                .font(Theme.Text.title)
                .foregroundStyle(Theme.Palette.text)
            Text(explanation)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            content.padding(.top, 6)

            Spacer(minLength: 0)

            modelLine
            footer
        }
        .id(step)
        .transition(.opacity)
        .frame(maxWidth: 480, maxHeight: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .animation(.easeInOut(duration: 0.2), value: step)
        // Neither permission announces a change, so while one is being asked for the state
        // is re-read every second. The flow notices the grant, not the user.
        .task(id: step) {
            // The try-it box is the destination; nothing is pasted anywhere while it is up.
            dictation.deliversText = step != .tryIt
            guard step == .howItWorks || step == .systemAudio || step == .tryIt
                || step == .microphone
            else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let hadAccessibility = permissions.accessibility == .granted
                // A denied system-audio grant flips in System Settings, which no
                // notification announces — and once determined, the probe re-checks
                // without prompting. The others only need their state re-read.
                if step == .systemAudio, permissions.systemAudio == .denied {
                    await permissions.requestSystemAudio()
                } else {
                    permissions.refresh()
                }
                // Only the dedicated ask page advances itself; the teaching pages tick
                // their card in place and leave the reading to the reader.
                if step == .systemAudio { onboarding.noteProgress() }
                // A grant made in System Settings leaves the user parked there. The
                // moment it lands, fetch them back — but only from System Settings, the
                // one place this flow sent them. Being in any other app is their choice.
                let grantJustLanded =
                    (!hadAccessibility && permissions.accessibility == .granted)
                        || onboarding.isAdvancing
                if grantJustLanded,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                       == "com.apple.systempreferences" {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onChange(of: permissions.systemAudio) { onboarding.noteProgress() }
        // The AI page moves on by itself the moment the key is proved, the way the
        // permission pages do when their grant lands: the tick is the answer.
        .onChange(of: providers.activeState.verification.isWorking) {
            if step == .connectAI { onboarding.noteProgress() }
        }
    }

    // MARK: - Words

    private var title: String {
        switch step {
        case .language: "Which languages do you speak?"
        case .systemAudio: "Let it hear the other side"
        case .howItWorks: "How it works"
        case .underTheHood: "What\u{2019}s inside"
        case .style: "How should it sound?"
        case .connectAI: "Connect an AI"
        case .withoutAI: "Sure you want to skip?"
        case .tryIt: "Try it"
        case .microphone: "Let it hear you"
        }
    }

    private var explanation: String {
        switch step {
        case .language:
            return "Pick every language you\u{2019}ll dictate in. Murmr Flow understands speech "
                + "on your Mac itself — nothing is sent anywhere. The one-off download (about "
                + "\(SpeechModel.parakeetV3.approximateSizeLabel)) starts when you continue."
        case .systemAudio:
            return "Murmr Flow needs to hear what this Mac plays — the other people in "
                + "your meetings, calls, or videos."
        case .howItWorks:
            return "Two keys, one for each job."
        case .underTheHood:
            return "What happens between what you say and what we write."
        case .style:
            return "Two things to pick, for Dictation and for the Notetaker:\n"
                + "\u{2022} Style — how the words are written.\n"
                + "\u{2022} Language — what they come out in. Dictate in French, land in "
                + "English; Off keeps the language you spoke."
        case .connectAI:
            if providers.activeState.verification.isWorking {
                return "\(providers.activeEntry.displayName) is connected and answering. "
                    + "Keep it, or pick another one here."
            }
            return "It turns raw speech into clean text: punctuation, your style, "
                + "translation. Pick one, paste its key, and we check it right away."
        case .withoutAI:
            return "Without an AI, your text will be rougher and less accurate. Here is "
                + "what changes:"
        case .tryIt:
            let key = settings.hotkey.displayName
            return settings.holdToTalk
                ? "Hold \(key), say a sentence, and let go. Your words appear below."
                : "Press \(key), say a sentence, and press it again. Your words appear below."
        case .microphone:
            return "Murmr Flow needs the microphone to turn speech into text."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .language:
            VStack(alignment: .leading, spacing: 10) {
                // A grid, not a flow: chips of different widths wrapping where they ran
                // out made every row start and end somewhere else, and twenty-six of them
                // read as a heap. Four equal columns line the flags up and the eye can scan
                // down them.
                //
                // Two grids with the same columns: the pair most people want on a row of
                // their own, then everything else A to Z. One grid with the pair at the
                // front would have run the alphabet on from the same row, and the order
                // stopped looking like an order.
                LazyVGrid(columns: Self.languageColumns, alignment: .leading, spacing: 6) {
                    ForEach(SpeechModel.featuredLanguages, id: \.self) { language in
                        languageChip(language)
                    }
                }
                LazyVGrid(columns: Self.languageColumns, alignment: .leading, spacing: 6) {
                    ForEach(SpeechModel.otherLanguages, id: \.self) { language in
                        languageChip(language)
                    }
                }
                packLine
            }
        case .systemAudio:
            permissionCard(
                symbol: "speaker.wave.2.fill",
                title: "System audio",
                state: permissions.systemAudio,
                level: permissions.systemAudio == .denied ? .bad : .waiting
            )
        case .howItWorks:
            VStack(alignment: .leading, spacing: 8) {
                howItWorks
                // The permission, on the page that explains what it powers. State only:
                // the ask itself lives in the footer, where every page's one action goes.
                inlinePermission(
                    symbol: "accessibility",
                    title: "Accessibility",
                    caption: "Murmr Flow needs access to your keyboard, so pressing "
                        + "\(settings.hotkey.displayName) anywhere starts a dictation.",
                    state: permissions.accessibility,
                    action: nil
                )
                // Developer builds only: an ad-hoc signature changes every build, and TCC
                // keeps the previous build's entry — the pane can show a toggle already on
                // while this build stays untrusted.
                if Self.signing.isAdHoc, askedForAccessibility,
                   permissions.accessibility != .granted {
                    WarningRow(
                        message: "If Murmr Flow is already switched on in that list, it is "
                            + "an earlier build\u{2019}s entry. Remove it with \u{2212}, then "
                            + "click the button again."
                    )
                }
            }
        case .underTheHood:
            underTheHood
        case .style:
            stylePicker
        case .connectAI:
            connectAI
        case .withoutAI:
            withoutAI
        case .tryIt:
            tryCard
        case .microphone:
            VStack(alignment: .leading, spacing: 8) {
                inlinePermission(
                    symbol: "mic.fill",
                    title: "Microphone",
                    caption: "Once allowed, press \(settings.hotkey.displayName) in any app "
                        + "and speak.",
                    state: permissions.microphone,
                    action: nil
                )
            }
        }
    }

    private static let languageColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6), count: 4
    )

    /// One language, on or off. Gold means chosen, and several can be — the fill and the
    /// brighter name say so without a tick that would push the longest names out of their
    /// column.
    private func languageChip(_ language: String) -> some View {
        choiceChip(
            language, flag: SpeechModel.flag(for: language), fills: true,
            isOn: languages.contains(language)
        ) {
            if languages.contains(language) {
                languages.remove(language)
            } else {
                languages.insert(language)
            }
        }
    }

    /// The one chip shape: a capsule that is gold when chosen. Fills its column in a grid,
    /// hugs its text in a flow.
    private func choiceChip(
        _ title: String,
        flag: String? = nil,
        image: NSImage? = nil,
        fills: Bool = false,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let flag {
                    // The system face, not Mona Sans: flags are emoji and only render there.
                    Text(flag).font(.system(size: 13))
                }
                if let image {
                    // A provider's mark, the same one Settings shows beside its row.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(title)
                    .font(Theme.Text.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if fills { Spacer(minLength: 0) }
            }
            // 8, not 10: "Portuguese" is the widest name and needs the two points to sit in
            // its column at full size rather than scaled.
            .padding(.horizontal, fills ? 8 : 11)
            .padding(.vertical, 6)
            .frame(maxWidth: fills ? .infinity : nil)
            .background {
                if isOn {
                    Capsule().fill(Theme.Palette.gold.opacity(0.14))
                }
            }
            .overlay(
                Capsule().stroke(
                    isOn ? Theme.Palette.gold.opacity(0.7) : Theme.Palette.hairline,
                    lineWidth: isOn ? 1.5 : 1
                )
            )
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Theme.Palette.text : Theme.Palette.muted)
        .disabled(loader.state.isBusy)
    }

    /// What the choice comes to: which pack, and whether it still has to be fetched. The
    /// model's name is trivia; "English only" or "multiple languages" is the decision.
    @ViewBuilder
    private var packLine: some View {
        if languages.isEmpty {
            Text("Pick at least one.")
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.faint)
        } else {
            let model = SpeechModel.covering(languages)
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.faint)
                Text("\(model.headline) — \(model.summary)")
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if SpeechModelLoader.isDownloaded(model) {
                    StatusChip(title: "Downloaded", level: .ok)
                } else {
                    StatusChip(title: model.approximateSizeLabel, level: .waiting)
                }
            }
        }
    }

    /// A permission living on a teaching page: what it is, why, its state, and the one
    /// button — ticking in place rather than flipping the page, so the reading finishes.
    private func inlinePermission(
        symbol: String,
        title: String,
        caption: String,
        state: PermissionState,
        action: (title: String, run: () -> Void)?
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 16))
                        .frame(width: 22)
                        .foregroundStyle(Theme.Palette.muted)
                    Text(title).font(Theme.Text.bodyStrong)
                    Spacer(minLength: 0)
                    if state == .granted {
                        StatusChip(title: "Allowed", level: .ok)
                    } else if let action {
                        Button(action.title, action: action.run)
                            .controlSize(.small)
                    } else {
                        StatusChip(
                            title: state.label,
                            level: state == .denied ? .bad : .waiting
                        )
                    }
                }
                Text(caption)
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionCard(
        symbol: String, title: String, state: PermissionState, level: StatusChip.Level
    ) -> some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .frame(width: 22)
                    .foregroundStyle(Theme.Palette.muted)
                Text(title).font(Theme.Text.bodyStrong)
                Spacer(minLength: 0)
                if state == .granted {
                    StatusChip(title: "Allowed", level: .ok)
                } else {
                    StatusChip(title: state.label, level: level)
                }
            }
        }
    }

    // MARK: - The two pages

    /// Two columns, one per job, each with its key drawn as a key. Nothing about how.
    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 8) {
            jobColumn(
                symbol: "mic.fill",
                title: "Dictation",
                slot: .dictation,
                key: settings.hotkey,
                steps: settings.holdToTalk
                    ? [
                        "Hold the key down, in any app — Mail, Slack, Notes.",
                        "Talk.",
                        "Let go. Your words appear where you were typing.",
                    ]
                    : [
                        "Press once, in any app — Mail, Slack, Notes.",
                        "Talk.",
                        "Press again. Your words appear where you were typing.",
                    ]
            )
            jobColumn(
                symbol: "person.2.wave.2",
                title: "Notetaker",
                slot: .meeting,
                key: settings.meetingHotkey,
                steps: [
                    "Press once when you want to take notes.",
                    "Talk, listen.",
                    "Press again when it ends. You get notes with who said what.",
                ]
            )
        }
    }

    private func jobColumn(
        symbol: String, title: String, slot: RebindSlot, key: Hotkey?, steps: [String]
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.gold)
                    Text(title).font(Theme.Text.bodyStrong)
                    Spacer(minLength: 0)
                }
                // The key is changeable where it is introduced — sending someone who
                // dislikes it off to Settings would be the flow admitting defeat.
                HStack(spacing: 8) {
                    if rebinding == slot {
                        Text("Press a key…")
                            .font(Theme.Text.small)
                            .foregroundStyle(Theme.Palette.gold)
                        Button("Cancel") {
                            rebindRecorder.stop()
                            rebinding = nil
                        }
                        .controlSize(.small)
                    } else if let key {
                        Keycap(text: key.displayName)
                        Button("Change") { beginRebind(slot) }
                            .controlSize(.small)
                    } else {
                        Button("Set a key") { beginRebind(slot) }
                            .controlSize(.small)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(Theme.Text.label)
                                .foregroundStyle(Theme.Palette.faint)
                                .frame(width: 10, alignment: .trailing)
                                .padding(.top, 2)
                            Text(step)
                                .font(Theme.Text.small)
                                .foregroundStyle(Theme.Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// The mechanism, once, in as few words as it takes. The one fact worth a
    /// non-technical reader's attention: the voice stays; only text can leave, and only
    /// if they set that up.
    private var underTheHood: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                infoRow(
                    number: 1,
                    symbol: "waveform",
                    title: "Speech to text",
                    detail: "What you say is transcribed into raw text, right here on "
                        + "this Mac."
                )
                Divider()
                infoRow(
                    number: 2,
                    symbol: "sparkles",
                    title: "AI polishes the raw text",
                    detail: "An AI cleans up what you said, applying the style you\u{2019}ll "
                        + "pick next — and can translate it into any language."
                )
            }
        }
    }

    private func infoRow(number: Int, symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 22)
                .foregroundStyle(Theme.Palette.gold)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number) · \(title)").font(Theme.Text.bodyStrong)
                Text(detail)
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Style

    /// Which prompt each job uses — the same choice Settings › AI clean-up offers, as chips.
    ///
    /// The honest line at the bottom is there because without a provider the choice does
    /// nothing, and the page must not promise otherwise.
    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    styleGroup(
                        title: "Dictation",
                        input: Self.dictationExampleInput,
                        translates: Binding(
                            get: { settings.dictationTranslates },
                            set: { settings.dictationTranslates = $0 }
                        ),
                        language: Binding(
                            get: { settings.dictationOutputLanguage },
                            set: { settings.dictationOutputLanguage = $0 }
                        ),
                        options: dictationStyles.map { ($0.id, $0.name) },
                        selected: prompts.dictationPromptID,
                        summary: Self.summary(for: prompts.dictationPrompt)
                    ) { prompts.dictationPromptID = $0 ?? prompts.dictationPromptID }

                    Divider()

                    styleGroup(
                        title: "Notetaker",
                        input: Self.meetingExampleInput,
                        translates: Binding(
                            get: { settings.notetakerTranslates },
                            set: { settings.notetakerTranslates = $0 }
                        ),
                        language: Binding(
                            get: { settings.notetakerOutputLanguage },
                            set: { settings.notetakerOutputLanguage = $0 }
                        ),
                        // Notes only. "As spoken" was offered here once and taken out:
                        // raw notes are what the app does *without* the AI, not a style.
                        options: [(PromptStore.meetingPreset.id, PromptStore.meetingPreset.name)],
                        selected: prompts.notetakerPromptID,
                        summary: prompts.notetakerPrompt.map(Self.summary) ?? "Saved exactly as transcribed."
                    ) { prompts.notetakerPromptID = $0 ?? prompts.notetakerPromptID }
                }
            }
            Text(styleFootnote)
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says where the AI stands, because without it the choices above do nothing. Three
    /// readings: it is the next page, it is already connected, or it was never set up.
    private var styleFootnote: String {
        if providers.activeState.verification.isWorking {
            return "Your AI is connected, so these apply from the first dictation."
        }
        if onboarding.plan.contains(.connectAI) {
            return "You\u{2019}ll connect the AI on the next screen."
        }
        return "Styles and translation need the AI clean-up set up in Settings. Until "
            + "then, you get your words exactly as spoken."
    }

    // MARK: - Connect an AI

    /// The catalogue as chips, then one card that walks through getting a key and takes
    /// it. Written for someone who has never made an API key: the three lines say where
    /// to go, what to press, and that pasting it here is the end of the job.
    private var connectAI: some View {
        let entry = providers.activeEntry
        let state = providers.activeState
        return VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(ProviderCatalog.all) { candidate in
                    choiceChip(
                        candidate.displayName,
                        image: ProviderMark.image(for: candidate),
                        isOn: candidate.id == providers.activeID
                    ) {
                        // Choosing here *is* choosing the one in use: on a first launch
                        // there is nothing else it could mean.
                        dictation.activateProvider(candidate.id)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    keyGuide(entry)

                    Divider()

                    if entry.requiresCustomBaseURL {
                        LabeledContent("Endpoint") {
                            TextField("https://…", text: providerBinding(\.baseURL))
                                .textFieldStyle(.roundedBorder)
                        }
                        .font(Theme.Text.small)
                        LabeledContent("Model") {
                            TextField("Model name", text: providerBinding(\.model))
                                .textFieldStyle(.roundedBorder)
                        }
                        .font(Theme.Text.small)
                    } else {
                        HStack(spacing: 8) {
                            Text("Model")
                                .font(Theme.Text.small)
                                .foregroundStyle(Theme.Palette.muted)
                            Text(state.model)
                                .font(Theme.Text.mono)
                                .foregroundStyle(Theme.Palette.muted)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            ProviderBadge(id: entry.id, providers: providers, dictation: dictation)
                        }
                    }

                    StoredSecretRow(
                        hasKey: providers.hasKey(entry.id),
                        isOptional: !entry.requiresKey,
                        onSave: { key in
                            try? providers.saveKey(key, for: entry.id)
                            dictation.testProvider(entry.id)
                        },
                        onRemove: { try? providers.deleteKey(for: entry.id) }
                    )

                    if entry.requiresCustomBaseURL {
                        HStack {
                            Spacer(minLength: 0)
                            ProviderBadge(id: entry.id, providers: providers, dictation: dictation)
                        }
                    }

                    if let reason = state.verification.failure {
                        Text(reason)
                            .font(Theme.Text.small)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Where the key comes from, as three numbered lines and the one button that opens
    /// the page. The host is named in the button so the person knows what they are about
    /// to see before they see it.
    @ViewBuilder
    private func keyGuide(_ entry: ProviderCatalog.Entry) -> some View {
        let host = entry.keyURL.flatMap { URL(string: $0)?.host } ?? ""
        let lines: [String] = entry.requiresCustomBaseURL
            ? [
                "Enter the address of a server that speaks the OpenAI chat API — Ollama, "
                    + "LM Studio, vLLM. Others won\u{2019}t work. Ollama on this Mac is "
                    + "http://localhost:11434/v1.",
                "Type the name of the model it serves.",
                "Add a key only if the server asks for one.",
            ]
            : [
                "Open \(host) and sign in. A free account is enough.",
                "Create an API key and copy it.",
                "Paste it below. We check it straight away.",
            ]
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(Theme.Text.label)
                        .foregroundStyle(Theme.Palette.faint)
                        .frame(width: 10, alignment: .trailing)
                        .padding(.top, 2)
                    Text(line)
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let keyURL = entry.keyURL, let url = URL(string: keyURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Get a key at \(host)", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    /// Endpoint and model for the Custom entry, written through the store so a change
    /// resets the proof, exactly as Settings does.
    private func providerBinding(_ field: KeyPath<ProviderStore.State, String>) -> Binding<String> {
        let id = providers.activeID
        return Binding(
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

    // MARK: - Without an AI

    /// What skipping costs, in the reader's terms. The primary button on this page goes
    /// *back*, so the easy click is the good one; going on is the quiet text.
    private var withoutAI: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    costLine("No punctuation or filler-word fixes. Words land exactly as spoken.")
                    costLine("Styles do nothing. Formal, Structure and Casual all give the same "
                             + "raw text.")
                    costLine("No translation, and notes are saved as a raw transcript.")
                }
            }
            Text("You can connect one any time in Settings \u{203A} AI clean-up.")
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.faint)
        }
    }

    private func costLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.gold)
                .padding(.top, 2)
            Text(text)
                .font(Theme.Text.body)
                .foregroundStyle(Theme.Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every prompt but the meeting one; custom prompts included, since someone may have
    /// made one before this ran.
    private var dictationStyles: [PromptPreset] {
        prompts.presets.filter { $0.id != PromptStore.meetingPreset.id }
    }

    private func styleGroup(
        title: String,
        input: String,
        translates: Binding<Bool>,
        language: Binding<String>,
        options: [(id: UUID?, name: String)],
        selected: UUID?,
        summary: String?,
        choose: @escaping (UUID?) -> Void
    ) -> some View {
        let name = options.first { $0.id == selected }?.name
        let example = name.flatMap { Self.examples[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(Theme.Text.bodyStrong)
                Spacer(minLength: 0)
                // The same value-menu Settings uses: translation is a per-job clean-up
                // choice exactly like the style, so it is offered where the styles are.
                TranslateMenu(translates: translates, language: language)
            }
            HStack(spacing: 8) {
                FlowLayout(spacing: 6) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        choiceChip(option.name, isOn: option.id == selected) {
                            choose(option.id)
                        }
                    }
                }
                Spacer(minLength: 0)
                if example != nil {
                    Button(previewing == title ? "Hide" : "Preview") {
                        previewing = previewing == title ? nil : title
                    }
                    .controlSize(.small)
                }
            }
            // A worked example beats a description: the same short sentence every time,
            // so styles compare against each other rather than against different inputs.
            if previewing == title, let example {
                // Translation wins over style in the example: one sentence per language
                // is teachable and checkable; twenty-six languages times six styles is
                // neither. The shape it demonstrates is the Default clean-up.
                let output = translates.wrappedValue
                    ? (Self.translatedExamples[language.wrappedValue] ?? example)
                    : example
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You say:")
                            .font(Theme.Text.label)
                            .foregroundStyle(Theme.Palette.faint)
                        Text("\u{201C}\(input)\u{201D}")
                            .font(Theme.Text.small)
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.leading, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("We write:")
                            .font(Theme.Text.label)
                            .foregroundStyle(Theme.Palette.faint)
                        Text(output)
                            .font(Theme.Text.small)
                            .foregroundStyle(Theme.Palette.muted)
                            .padding(.leading, 12)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// One generic sentence per job, per-style renderings out — hardcoded, because the
    /// point is teaching the difference, not exercising the model on a screen that may
    /// not have a provider yet. The two inputs carry the same content, which is what
    /// lets one table of translations serve them both.
    static let dictationExampleInput =
        "uh so can we move the meeting to thursday and um also send me the report"
    static let meetingExampleInput =
        "so are we good to move the meeting to thursday yeah thursday works for me "
        + "perfect and can you send me the report after the call sure will do"

    /// The example sentence, cleaned and translated — hardcoded like the styles, one per
    /// offered language, so picking a language in the 文A menu shows the promise being
    /// kept rather than an English sentence under a French flag.
    static let translatedExamples: [String: String] = [
        "English": "Can we move the meeting to Thursday? And also send me the report.",
        "French": "Peut-on déplacer la réunion à jeudi ? Et envoie-moi aussi le rapport.",
        "German": "Können wir das Meeting auf Donnerstag verschieben? Und schick mir auch den Bericht.",
        "Spanish": "¿Podemos mover la reunión al jueves? Y envíame también el informe.",
        "Italian": "Possiamo spostare la riunione a giovedì? E mandami anche il report.",
        "Portuguese": "Podemos mudar a reunião para quinta-feira? E envia-me também o relatório.",
        "Dutch": "Kunnen we de meeting naar donderdag verplaatsen? En stuur me ook het rapport.",
        "Swedish": "Kan vi flytta mötet till torsdag? Och skicka mig rapporten också.",
        "Danish": "Kan vi flytte mødet til torsdag? Og send mig også rapporten.",
        "Finnish": "Voisimmeko siirtää kokouksen torstaille? Ja lähetä minulle myös raportti.",
        "Polish": "Czy możemy przenieść spotkanie na czwartek? I wyślij mi też raport.",
        "Czech": "Můžeme přesunout schůzku na čtvrtek? A pošli mi také zprávu.",
        "Slovak": "Môžeme presunúť stretnutie na štvrtok? A pošli mi aj správu.",
        "Slovenian": "Lahko sestanek prestavimo na četrtek? In pošlji mi še poročilo.",
        "Croatian": "Možemo li sastanak pomaknuti na četvrtak? I pošalji mi i izvještaj.",
        "Hungarian": "Áttehetjük a megbeszélést csütörtökre? És küldd el nekem a jelentést is.",
        "Romanian": "Putem muta ședința joi? Și trimite-mi și raportul.",
        "Bulgarian": "Можем ли да преместим срещата за четвъртък? И ми изпрати и доклада.",
        "Russian": "Можем перенести встречу на четверг? И пришли мне ещё отчёт.",
        "Ukrainian": "Можемо перенести зустріч на четвер? І надішли мені ще звіт.",
        "Greek": "Μπορούμε να μεταφέρουμε τη συνάντηση την Πέμπτη; Και στείλε μου και την αναφορά.",
        "Estonian": "Kas saame koosoleku neljapäevale tõsta? Ja saada mulle ka aruanne.",
        "Latvian": "Vai varam pārcelt sapulci uz ceturtdienu? Un atsūti man arī atskaiti.",
        "Lithuanian": "Ar galime perkelti susitikimą į ketvirtadienį? Ir atsiųsk man ir ataskaitą.",
        "Maltese": "Nistgħu nċaqilqu l-laqgħa għall-Ħamis? U ibgħatli wkoll ir-rapport.",
        "Japanese": "会議を木曜日に変更できますか？あとレポートも送ってください。",
    ]

    static let examples: [String: String] = [
        "Default": "Can we move the meeting to Thursday? And also send me the report.",
        "Structure": "Two asks:\n– move the meeting to Thursday\n– send the report",
        "Formal": "Could we move the meeting to Thursday? Please also send me the report.",
        "Casual": "Can we push the meeting to Thursday? And send me the report too.",
        "Notes": "Decided: meeting moves to Thursday.\nTo-do: send the report.",
    ]

    /// One line per built-in, in the reader's terms. A custom prompt describes itself by
    /// its name.
    private static func summary(for preset: PromptPreset) -> String? {
        guard preset.isBuiltIn else { return nil }
        return [
            "Default": "Punctuation and filler words fixed. Nothing else changed.",
            "Structure": "Rambling turned into paragraphs and lists.",
            "Formal": "Polished, professional wording.",
            "Casual": "Relaxed and conversational.",
            "Notes": "Who said what, decisions, and to-dos.",
        ][preset.name]
    }

    // MARK: - Try it

    /// The key, a box the words appear in, and a button for when the key can't fire —
    /// Accessibility skipped, or the watcher not yet armed.
    ///
    /// The box is **not a text field.** It was, so the paste a dictation sends had somewhere
    /// to land — and so did the keyboard, which made it a place to type. What it shows now
    /// comes straight from the dictation: the words as they are recognised, then the final
    /// sentence. Nothing to type into, and the proof is the same.
    private var tryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The ask lives where the need does: this page is the first thing that
            // listens. State only — the footer's primary button carries the ask.
            if permissions.microphone != .granted {
                inlinePermission(
                    symbol: "mic.fill",
                    title: "Microphone",
                    caption: "Murmr Flow needs to hear you to turn speech into text.",
                    state: permissions.microphone,
                    action: nil
                )
            }
            Card(highlighted: dictation.stage.isRecording) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Keycap(text: settings.hotkey.displayName)
                        Text(tryHeadline)
                            .font(Theme.Text.bodyStrong)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button(dictation.stage.isRecording ? "Stop" : "Dictate") {
                            if dictation.stage.isRecording {
                                Task { await dictation.endDictation() }
                            } else if permissions.microphone == .notDetermined {
                                // The same direction as the footer's Allow: asking is
                                // what this click has to mean while there is no grant.
                                Task { await permissions.requestMicrophone() }
                            } else if permissions.microphone == .denied {
                                permissions.openMicrophoneSettings()
                            } else {
                                dictation.beginDictation()
                            }
                        }
                        .controlSize(.small)
                        .disabled(dictation.stage.isBusy && !dictation.stage.isRecording)
                    }

                    Divider()

                    Text(heard ?? "Your words will appear here.")
                        .font(Theme.Text.body)
                        .foregroundStyle(heard == nil ? Theme.Palette.faint : Theme.Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                        .textSelection(.enabled)
                }
            }

            if let detail = dictation.stage.detail {
                WarningRow(message: detail)
            } else if heard != nil, !dictation.stage.isBusy {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.ok)
                    Text("That\u{2019}s it. It works the same in any app.")
                        .font(Theme.Text.body)
                }
            }

            if !dictation.hotkeyActive, permissions.accessibility != .granted {
                WarningRow(
                    message: "Accessibility is off, so the key won\u{2019}t work yet — use the "
                        + "button for now.",
                    action: ("Allow", { permissions.openAccessibilitySettings() })
                )
            }

            // fn is also the system's emoji key until told otherwise. Said here, on the
            // page where the key is first pressed, rather than left for the picker to
            // explain.
            if let warning = HotkeyMonitor.systemFnWarning(for: settings.hotkey) {
                WarningRow(
                    message: warning,
                    action: ("Open Keyboard Settings", { HotkeyMonitor.openKeyboardSettings() })
                )
            }
        }
    }

    /// Live words while recording, the finished sentence after.
    private var heard: String? {
        if dictation.stage.isRecording {
            return dictation.preview.isEmpty ? nil : dictation.preview
        }
        return dictation.lastRun?.finalText
    }

    private var tryHeadline: String {
        if dictation.stage.isRecording {
            return String(format: "Listening — %.1fs", dictation.elapsed)
        }
        if dictation.stage.isBusy { return dictation.stage.label }
        return settings.holdToTalk ? "Hold and speak" : "Press and speak"
    }

    // MARK: - The download, in the background

    /// The download started on the first screen keeps going under the rest; this is the one
    /// line that says so. On the last screen it is what decides whether the key will do
    /// anything yet.
    @ViewBuilder
    private var modelLine: some View {
        if step != .language {
            switch loader.state {
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text("Downloading — \(Int(fraction * 100))%")
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.muted)
                }
            case .preparing, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Getting ready…")
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.muted)
                }
            case .failed(let message):
                WarningRow(
                    message: message,
                    action: ("Retry", { Task { await dictation.warmUp() } })
                )
            case .ready:
                if step == .tryIt {
                    StatusChip(title: "Ready to listen", level: .ok)
                }
            case .notLoaded:
                EmptyView()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Rereading the previous page must not cost a restart of the flow.
            if onboarding.position > 1 {
                Button("‹ Back") { onboarding.back() }
                    .buttonStyle(.plain)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.faint)
            }
            // Only while the primary button is an ask: once the grant is in (or on a
            // page whose primary is already Continue), skipping means nothing.
            if showsSkip {
                Button(skipTitle) { skip() }
                    .buttonStyle(.plain)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
            if let action = primaryAction {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // Nothing picked means nothing to decide from; a key that has not
                    // answered yet is not a connection.
                    .disabled(
                        (step == .language && languages.isEmpty)
                            || (step == .connectAI
                                && !providers.activeState.verification.isWorking)
                    )
            }
        }
    }

    /// The quiet way past. Named for what it does on the one page where "skip" would be
    /// the wrong word: there, the question has already been asked once.
    private var skipTitle: String {
        step == .withoutAI ? "Continue without AI" : "Skip for now"
    }

    /// The one button.
    private var primaryAction: (title: String, run: () -> Void)? {
        switch step {
        case .language:
            return ("Continue", { choose(SpeechModel.covering(languages)) })
        case .systemAudio:
            switch permissions.systemAudio {
            case .granted:
                return ("Continue", { onboarding.advance() })
            case .notDetermined:
                return ("Allow system audio", {
                    Task {
                        await permissions.requestSystemAudio()
                        onboarding.noteProgress()
                    }
                })
            case .denied:
                return ("Open System Settings", { permissions.openSystemAudioSettings() })
            }
        case .howItWorks:
            if permissions.accessibility == .granted {
                return ("Continue", { onboarding.advance() })
            }
            return ("Open System Settings", {
                // Straight to the pane, with the app already listed — one step. Apple's
                // dialog is kept for a second click: it is the way that is guaranteed
                // to add the app to the list.
                if askedForAccessibility {
                    permissions.promptAccessibility()
                } else {
                    askedForAccessibility = true
                    permissions.requestAccessibility()
                }
            })
        case .underTheHood, .style, .connectAI:
            return ("Continue", { onboarding.advance() })
        case .withoutAI:
            // Back to the page that was declined: the easy click is the good one.
            return ("Connect an AI", { onboarding.back() })
        case .tryIt, .microphone:
            switch permissions.microphone {
            case .granted:
                return ("Done", { services.finishOnboarding() })
            case .notDetermined:
                return ("Allow microphone", {
                    Task { await permissions.requestMicrophone() }
                })
            case .denied:
                return ("Open System Settings", { permissions.openMicrophoneSettings() })
            }
        }
    }

    // MARK: - Actions

    private func choose(_ model: SpeechModel) {
        dictation.changeSpeechModel(model)
        Task { await dictation.warmUp() }
        onboarding.advance()
    }

    private func beginRebind(_ slot: RebindSlot) {
        rebinding = slot
        rebindRecorder.onFinish = { captured in
            defer { rebinding = nil }
            guard let captured else { return }
            switch slot {
            case .dictation:
                // The two binds must not collide; a rejected capture just keeps the old key.
                guard captured != settings.meetingHotkey else { return }
                services.changeDictationHotkey(to: captured)
            case .meeting:
                guard captured != settings.hotkey else { return }
                services.changeMeetingHotkey(to: captured)
            }
        }
        rebindRecorder.start()
    }

    /// Skipping the language question keeps the default and downloads that: leaving with
    /// no model at all would make the last screen a dead end.
    private var showsSkip: Bool {
        switch step {
        case .language: true
        case .howItWorks: permissions.accessibility != .granted
        case .systemAudio: permissions.systemAudio != .granted
        case .tryIt, .microphone: permissions.microphone != .granted
        case .connectAI: !providers.activeState.verification.isWorking
        case .withoutAI: true
        case .underTheHood, .style: false
        }
    }

    private func skip() {
        switch step {
        case .language:
            choose(speech.activeModel)
        case .tryIt, .microphone:
            services.finishOnboarding()
        case .connectAI:
            onboarding.declineAI()
        case .withoutAI:
            onboarding.continueWithoutAI()
        default:
            onboarding.advance()
        }
    }
}
