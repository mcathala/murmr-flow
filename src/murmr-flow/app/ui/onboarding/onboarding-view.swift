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
    private var step: OnboardingCoordinator.Step { onboarding.step }

    /// The languages picked on the first screen. They decide the model; the person never
    /// sees a model name.
    @State private var languages: Set<String> = []

    /// Whether the Accessibility pane has been opened once already from this step.
    @State private var askedForAccessibility = false

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
            guard step == .microphone || step == .accessibility || step == .systemAudio
            else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // A denied system-audio grant flips in System Settings, which no
                // notification announces — and once determined, the probe re-checks
                // without prompting. The others only need their state re-read.
                if step == .systemAudio, permissions.systemAudio == .denied {
                    await permissions.requestSystemAudio()
                } else {
                    permissions.refresh()
                }
                onboarding.noteProgress()
                // A grant made in System Settings leaves the user parked there. The
                // moment it lands, fetch them back — but only from System Settings, the
                // one place this flow sent them. The first version reclaimed focus from
                // whatever was frontmost, and yanked the user out of their browser the
                // instant a grant registered. Being in any other app is their choice.
                if onboarding.isAdvancing,
                   NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                       == "com.apple.systempreferences" {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .onChange(of: permissions.microphone) { onboarding.noteProgress() }
        .onChange(of: permissions.accessibility) { onboarding.noteProgress() }
        .onChange(of: permissions.systemAudio) { onboarding.noteProgress() }
    }

    // MARK: - Words

    private var title: String {
        switch step {
        case .language: "Which languages do you speak?"
        case .microphone: "Allow the microphone"
        case .accessibility: "Turn on Accessibility"
        case .systemAudio: "Let it hear the meeting"
        case .howItWorks: "How it works"
        case .underTheHood: "What\u{2019}s inside"
        case .style: "How should it sound?"
        case .tryIt: "Try it"
        }
    }

    private var explanation: String {
        switch step {
        case .language:
            return "Pick every language you\u{2019}ll dictate in. Murmr Flow understands speech "
                + "on your Mac itself — nothing is sent anywhere. The one-off download (about "
                + "\(SpeechModel.parakeetV3.approximateSizeLabel)) starts when you continue."
        case .microphone:
            return "Murmr Flow needs to hear you to turn speech into text. Everything stays "
                + "on this Mac."
        case .accessibility:
            return "One last permission: this is what lets \(settings.hotkey.displayName) "
                + "work in any app, and what types your words where your cursor is. Click "
                + "the button, then turn on Murmr Flow in the list that opens."
        case .systemAudio:
            return "Meeting notes have two sides: your microphone is \u{201C}You\u{201D}, and "
                + "what this Mac plays is \u{201C}Them\u{201D}. macOS files this under "
                + "\u{201C}Screen & System Audio Recording\u{201D}, but only the audio is "
                + "taken — your screen stays yours."
        case .howItWorks:
            return "Two keys, one for each job."
        case .underTheHood:
            return "Dictation and meeting notes both go through the same two steps."
        case .style:
            return "Pick a style for each. You can change it any time."
        case .tryIt:
            let key = settings.hotkey.displayName
            return settings.holdToTalk
                ? "Hold \(key), say a sentence, and let go. Your words appear below."
                : "Press \(key), say a sentence, and press it again. Your words appear below."
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
        case .microphone:
            permissionCard(
                symbol: "mic.fill",
                title: "Microphone",
                state: permissions.microphone,
                level: permissions.microphone == .denied ? .bad : .waiting
            )
        case .accessibility:
            VStack(alignment: .leading, spacing: 8) {
                // "Not granted" is where every install starts, so it isn't drawn as a fault.
                permissionCard(
                    symbol: "accessibility",
                    title: "Accessibility",
                    state: permissions.accessibility,
                    level: .waiting
                )
                // Developer builds only, and only once the pane has been opened and the
                // grant still hasn't landed. An ad-hoc signature changes on every build and
                // TCC keeps the previous build's entry, so the list shows a toggle already
                // on while this build stays untrusted ("Failed to match existing code
                // requirement" in tccd's log). Nothing a first-time user will ever see; the
                // one person who does needs to be told what to click.
                if Self.signing.isAdHoc, askedForAccessibility,
                   permissions.accessibility != .granted {
                    WarningRow(
                        message: "If Murmr Flow is already switched on in that list, it is "
                            + "an earlier build\u{2019}s entry. Remove it with \u{2212}, then "
                            + "click the button again."
                    )
                }
            }
        case .systemAudio:
            permissionCard(
                symbol: "speaker.wave.2.fill",
                title: "System audio",
                state: permissions.systemAudio,
                level: permissions.systemAudio == .denied ? .bad : .waiting
            )
        case .howItWorks:
            howItWorks
        case .underTheHood:
            underTheHood
        case .style:
            stylePicker
        case .tryIt:
            tryCard
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
                title: "Meeting notes",
                key: settings.meetingHotkey,
                steps: [
                    "Press once when the meeting starts.",
                    "Talk, listen.",
                    "Press again when it ends. You get notes with who said what.",
                ]
            )
        }
    }

    private func jobColumn(
        symbol: String, title: String, key: Hotkey?, steps: [String]
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
                if let key {
                    Keycap(text: key.displayName)
                } else {
                    Text("No key yet — set one in Settings › Hotkeys.")
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.faint)
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
                    detail: "On this Mac. Your voice never leaves it."
                )
                Divider()
                infoRow(
                    number: 2,
                    symbol: "sparkles",
                    title: "AI clean-up",
                    detail: "Punctuation, filler words, your spellings — by an AI like "
                        + "ChatGPT. Optional; only the text is sent, never the audio."
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
                        options: dictationStyles.map { ($0.id, $0.name) },
                        selected: prompts.dictationPromptID,
                        summary: Self.summary(for: prompts.dictationPrompt)
                    ) { prompts.dictationPromptID = $0 ?? prompts.dictationPromptID }

                    Divider()

                    styleGroup(
                        title: "Meeting notes",
                        options: [(PromptStore.meetingPreset.id, PromptStore.meetingPreset.name),
                                  (nil, "As spoken")],
                        selected: prompts.notetakerPromptID,
                        summary: prompts.notetakerPrompt.map(Self.summary) ?? "Saved exactly as transcribed."
                    ) { prompts.notetakerPromptID = $0 }
                }
            }
            Text("Styles need the AI clean-up set up in Settings. Until then, you get your "
                 + "words exactly as spoken.")
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.faint)
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
        options: [(id: UUID?, name: String)],
        selected: UUID?,
        summary: String?,
        choose: @escaping (UUID?) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.Text.bodyStrong)
            FlowLayout(spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    choiceChip(option.name, isOn: option.id == selected) { choose(option.id) }
                }
            }
            if let summary {
                Text(summary)
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line per built-in, in the reader's terms. A custom prompt describes itself by
    /// its name.
    private static func summary(for preset: PromptPreset) -> String? {
        guard preset.isBuiltIn else { return nil }
        return [
            "Default": "Punctuation and filler words fixed. Nothing else changed.",
            "Structure": "Rambling turned into paragraphs and lists.",
            "Formal": "Polished, professional wording.",
            "Casual": "Relaxed and conversational.",
            "Meeting": "Who said what, decisions, and to-dos.",
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
                    action: ("Open Settings", { permissions.openAccessibilitySettings() })
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
            if step.isSetup {
                Button("Skip for now") { skip() }
                    .buttonStyle(.plain)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 0)
            if let action = primaryAction {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // Nothing picked means nothing to decide from.
                    .disabled(step == .language && languages.isEmpty)
            }
        }
    }

    /// The one button.
    private var primaryAction: (title: String, run: () -> Void)? {
        switch step {
        case .language:
            return ("Continue", { choose(SpeechModel.covering(languages)) })
        case .microphone:
            switch permissions.microphone {
            case .granted:
                return ("Continue", { onboarding.advance() })
            case .notDetermined:
                return ("Allow microphone", {
                    Task {
                        await permissions.requestMicrophone()
                        onboarding.noteProgress()
                    }
                })
            case .denied:
                return ("Open System Settings", { permissions.openMicrophoneSettings() })
            }
        case .accessibility:
            if permissions.accessibility == .granted {
                return ("Continue", { onboarding.advance() })
            }
            return ("Open System Settings", {
                // Straight to the pane, with the app already listed — one step. Apple's
                // dialog would do the listing too, but it is a screen of its own whose only
                // useful button opens this same pane, so it is kept for a second click: the
                // user saw the list without Murmr Flow in it, and the dialog is the way that
                // is guaranteed to add it.
                if askedForAccessibility {
                    permissions.promptAccessibility()
                } else {
                    askedForAccessibility = true
                    permissions.requestAccessibility()
                }
            })
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
        case .howItWorks, .underTheHood, .style:
            return ("Continue", { onboarding.advance() })
        case .tryIt:
            return ("Done", { services.finishOnboarding() })
        }
    }

    // MARK: - Actions

    private func choose(_ model: SpeechModel) {
        dictation.changeSpeechModel(model)
        Task { await dictation.warmUp() }
        onboarding.advance()
    }

    /// Skipping the language question keeps the default and downloads that: leaving with
    /// no model at all would make the last screen a dead end.
    private func skip() {
        if step == .language {
            choose(speech.activeModel)
        } else {
            onboarding.advance()
        }
    }
}
