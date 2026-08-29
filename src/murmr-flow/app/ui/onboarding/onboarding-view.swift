import SwiftUI

/// First launch, as four screens in the main window with the sidebar out of the way.
///
/// In the window rather than a window of its own: `AppDelegate` already has to poll for
/// the main window and drag it on screen, and a second window would double every one of
/// those problems for a screen that is seen once.
///
/// The shape is the same on every step — what this is, one line on why, the thing's current
/// state, and a footer with the way past on the left and the one action on the right. The
/// action is in the footer and nowhere else, so there is never a button in the middle of
/// the screen and another at the bottom asking the same question.
struct OnboardingView: View {

    let services: AppServices

    private var onboarding: OnboardingCoordinator { services.onboarding }
    private var permissions: PermissionManager { services.permissions }
    private var dictation: DictationCoordinator { services.dictation }
    private var loader: SpeechModelLoader { services.dictation.loader }
    private var speech: SpeechModelStore { services.speech }
    private var step: OnboardingCoordinator.Step { onboarding.step }

    /// Where the try-it dictation lands. Its contents are the proof.
    @State private var tried = ""
    /// Whether the Accessibility pane has been opened once already from this step.
    @State private var askedForAccessibility = false

    /// Read once: the signature does not change while the process runs.
    private static let signing = SigningInfo.current()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Step \(step.number) of \(OnboardingCoordinator.Step.count)")
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
        .frame(maxWidth: 480, maxHeight: 440, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(48)
        .animation(.easeInOut(duration: 0.2), value: step)
        // Neither permission announces a change, so while one is being asked for the state
        // is re-read every second. The flow notices the grant, not the user.
        .task(id: step) {
            guard step == .microphone || step == .accessibility else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissions.refresh()
                onboarding.noteProgress()
            }
        }
        .onChange(of: permissions.microphone) { onboarding.noteProgress() }
        .onChange(of: permissions.accessibility) { onboarding.noteProgress() }
    }

    // MARK: - Words

    private var title: String {
        switch step {
        case .language: "Which languages do you dictate in?"
        case .microphone: "Allow the microphone"
        case .accessibility: "Turn on Accessibility"
        case .tryIt: "Try it"
        }
    }

    private var explanation: String {
        switch step {
        case .language:
            return "Speech is turned into text by a model that runs on this Mac. It downloads "
                + "once — about \(SpeechModel.parakeetV3.approximateSizeMB) MB — and starts as "
                + "soon as you choose."
        case .microphone:
            return "Murmr Flow listens only while a dictation or a meeting is running. Audio is "
                + "transcribed on this Mac and never uploaded."
        case .accessibility:
            return "This is what lets the hotkey work in any app, and what puts the text where "
                + "your cursor is. macOS has no prompt for it — click below, then turn on "
                + "Murmr Flow in the list. This screen moves on by itself once it's on."
        case .tryIt:
            let key = dictation.settings.hotkey.displayName
            return dictation.settings.holdToTalk
                ? "Hold \(key), say a sentence, and let go. The text lands wherever your "
                    + "cursor is — for now, that's the box below."
                : "Press \(key), say a sentence, and press it again. The text lands wherever "
                    + "your cursor is — for now, that's the box below."
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .language:
            VStack(spacing: 8) {
                ForEach(SpeechModel.allCases) { model in
                    modelCard(model)
                }
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
                // Developer builds only. An ad-hoc signature changes on every build, and
                // TCC keeps the previous build's entry — so the pane can show the toggle
                // already on while this build stays untrusted. Say so here, at the moment it
                // is confusing, rather than leaving "Not granted" to argue with a lit toggle.
                if Self.signing.isAdHoc {
                    WarningRow(
                        message: "This build is ad-hoc signed, so the list may show an "
                            + "earlier build's toggle already on. If it is, turn it off and "
                            + "on again — or remove it with − and click the button again."
                    )
                }
            }
        case .tryIt:
            tryCard
        }
    }

    /// One of the two models. The card is the answer: clicking it chooses and moves on.
    private func modelCard(_ model: SpeechModel) -> some View {
        Button {
            choose(model)
        } label: {
            Card {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.headline)
                            .font(Theme.Text.bodyStrong)
                            .foregroundStyle(Theme.Palette.text)
                        Text(model.summary)
                            .font(Theme.Text.small)
                            .foregroundStyle(Theme.Palette.muted)
                    }
                    Spacer(minLength: 0)
                    if SpeechModelLoader.isDownloaded(model) {
                        StatusChip(title: "Downloaded", level: .waiting)
                    } else {
                        StatusChip(title: "\(model.approximateSizeMB) MB", level: .waiting)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(loader.state.isBusy)
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

    /// The hotkey, a box for the text to land in, and a button for when the hotkey can't
    /// fire — Accessibility skipped, or the watcher not yet armed.
    private var tryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Card(highlighted: dictation.stage.isRecording) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Keycap(text: dictation.settings.hotkey.displayName)
                        Text(tryHeadline)
                            .font(Theme.Text.bodyStrong)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button(dictation.stage.isRecording ? "Stop" : "Dictate") {
                            if dictation.stage.isRecording {
                                Task { await dictation.endDictation() }
                            } else {
                                fieldFocused = true
                                dictation.beginDictation()
                            }
                        }
                        .controlSize(.small)
                        .disabled(dictation.stage.isBusy && !dictation.stage.isRecording)
                    }

                    Divider()

                    TextField("The text lands here", text: $tried, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.Text.body)
                        .lineLimit(3...6)
                        .focused($fieldFocused)
                }
            }
            .task {
                // After layout, or the request is made to a field that isn't there yet.
                try? await Task.sleep(for: .milliseconds(200))
                fieldFocused = true
            }

            if dictation.stage.isRecording, !dictation.preview.isEmpty {
                Text(dictation.preview)
                    .font(Theme.Text.small)
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(2)
            } else if let detail = dictation.stage.detail {
                WarningRow(message: detail)
            } else if let note = dictation.lastRun?.note {
                // Without Accessibility the text is copied rather than pasted; say so
                // rather than leaving an empty box that looks like nothing was heard.
                WarningRow(message: note)
            } else if dictation.lastRun != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.ok)
                    Text("That's the whole thing. It works the same in any app.")
                        .font(Theme.Text.body)
                }
            }

            if !dictation.hotkeyActive, permissions.accessibility != .granted {
                WarningRow(
                    message: "Accessibility is off, so the hotkey won't fire. Use the button "
                        + "for now — Home will show how to fix it.",
                    action: ("Open Settings", { permissions.openAccessibilitySettings() })
                )
            }
        }
    }

    private var tryHeadline: String {
        if dictation.stage.isRecording {
            return String(format: "Listening — %.1fs", dictation.elapsed)
        }
        if dictation.stage.isBusy { return dictation.stage.label }
        return dictation.settings.holdToTalk ? "Hold and speak" : "Press and speak"
    }

    // MARK: - The model, in the background

    /// The download started on the first screen keeps going under the next two; this is
    /// the one line that says so. On the last screen it is what decides whether the hotkey
    /// will do anything yet.
    @ViewBuilder
    private var modelLine: some View {
        if step != .language {
            switch loader.state {
            case .downloading(let fraction):
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 120)
                    Text("Downloading the speech model — \(Int(fraction * 100))%")
                        .font(Theme.Text.small)
                        .foregroundStyle(Theme.Palette.muted)
                }
            case .preparing, .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Getting the speech model ready…")
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
                    StatusChip(title: "Speech model ready", level: .ok)
                }
            case .notLoaded:
                EmptyView()
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .tryIt {
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
            }
        }
    }

    /// The one button. Nothing on the first screen: the two cards are the answer.
    private var primaryAction: (title: String, run: () -> Void)? {
        switch step {
        case .language:
            return nil
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
