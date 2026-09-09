import SwiftUI

/// Home: what you made, and anything that needs attention.
///
/// It began as a lobby whose only claim was a Start button, which moved to the toolbar.
/// Insights lived here too and has since moved to its own section — the two were
/// competing for one scroll, and they are read differently: this is glanceable, that is
/// something you go and study.
struct HomeView: View {

    let services: AppServices
    let onOpen: (MainWindow.Route) -> Void

    var body: some View {
        PaneScroll {
            status
            if let trouble { WarningRow(message: trouble.message, action: trouble.action) }
            // Not a fault — the app works without it — but the one setup step with no
            // system prompt to surface it, so Home says it once, only while it is true.
            if let update = services.updates.available {
                WarningRow(
                    message: "Murmr Flow \(update.version) is out.",
                    action: ("Download", { NSWorkspace.shared.open(update.url) })
                )
            }
            if needsProvider {
                WarningRow(
                    message: "No AI provider yet — your words arrive exactly as spoken.",
                    action: ("Set up", { services.openSettings(.aiCleanup) })
                )
            }

            SectionLabel(title: "Audio")
            AudioDevicesCard(services: services)

            SectionLabel(title: "Recents")
            recents

            if !history.isEmpty { summary }
        }
        .onAppear { services.notes.reload() }
    }

    // MARK: - Status

    /// The two halves of the pipeline, and nothing else. A dead hotkey is a *problem*, so
    /// it belongs in the warning below rather than sitting here as a status.
    private var status: some View {
        HStack(spacing: 8) {
            StatusChip(title: "Speech model", level: speechModelLevel)
            // Switched off on purpose is a choice, not a state to worry about, so the
            // chip says which rather than going amber over a configured-nothing.
            if services.settings.cleanupEnabled {
                StatusChip(title: "AI provider", level: aiProviderLevel)
            } else {
                StatusChip(title: "Clean-up off", level: .waiting)
            }
            Spacer(minLength: 0)
        }
    }

    private var speechModelLevel: StatusChip.Level {
        let speech = services.speech
        switch speech.verification(for: speech.activeModel) {
        case .working: return .ok
        case .failed: return .bad
        case .untested:
            // Loaded is not the same as proved. Until the test has run, the honest
            // reading is "ready to try", not "working".
            return services.dictation.loader.state == .ready ? .waiting : .bad
        }
    }

    private var aiProviderLevel: StatusChip.Level {
        let providers = services.providers
        switch providers.state(for: providers.activeID).verification {
        case .working: return .ok
        case .failed: return .bad
        // Configured but never exercised is amber, not green: a pasted key is not a
        // working key, and this chip is the one place that claim is made.
        case .untested: return providers.isUsable(providers.activeID) ? .waiting : .bad
        }
    }

    /// Clean-up is promised somewhere — a switch on, a style or a language picked in
    /// onboarding — but no provider can deliver it.
    private var needsProvider: Bool {
        (services.settings.cleanupEnabled || services.settings.notetakerCleanupEnabled)
            && !services.providers.isUsable(services.providers.activeID)
    }

    /// Faults that are Home's to report. A missing permission is not one any more: the
    /// window shows that above every section, so it is seen wherever you are.
    private var trouble: (message: String, action: (title: String, run: () -> Void))? {
        if services.permissions.allGranted, !services.dictation.hotkeyActive {
            // The button does what the sentence says. It used to say "Restart" over a
            // button that only quit.
            return (
                "The hotkey watcher isn't running. Quit and reopen Murmr Flow.",
                ("Quit and reopen", { services.relaunch() })
            )
        }
        if case .failed(let message) = services.dictation.loader.state {
            return (message, ("Retry", { Task { await services.dictation.warmUp() } }))
        }
        return nil
    }

    // MARK: - Summary

    /// Three numbers, and the row itself is the way through to the rest.
    ///
    /// This replaced a "See your insights" button. A button pointing at content is weaker
    /// than the content: it costs the same click and tells you nothing on the way past.
    ///
    /// Volume, payoff, habit — chosen because each answers a different question. Pace is
    /// the interesting one and deliberately not here: it is a curiosity rather than
    /// something you act on, so it belongs where you went looking for it.
    private var summary: some View {
        let insights = Insights.compute(from: history)
        return Button {
            onOpen(.insights)
        } label: {
            Card {
                HStack(spacing: 0) {
                    stat("\(insights.wordsDictated)", "words this week")
                    statDivider
                    stat(Insights.shortDuration(insights.timeSaved), "saved")
                    statDivider
                    stat(
                        "\(insights.streakDays)",
                        insights.streakDays == 1 ? "day streak" : "days running"
                    )
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Open Insights")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 92, alignment: .leading)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 26)
            .padding(.trailing, 16)
    }

    // MARK: - Recents

    private var history: [DictationRecord] { services.history.dictations }

    /// One merged list, not two. Dictation rows carry the app they went to, which is free
    /// now that the panel tracks it.
    @ViewBuilder
    private var recents: some View {
        let items = RecentItem.merge(
            dictations: services.history.dictations,
            notes: services.notes.notes,
            limit: 5
        )

        if items.isEmpty {
            Card {
                Text("\(services.settings.hotkeyPhrase) and speak, or open Notetaker and "
                     + "press Start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Card {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            // A note opens as the note, the way the menu bar's rows
                            // already did; a row that only opened the section it lives in
                            // made you find it twice.
                            if let note = item.note {
                                services.notes.open(note)
                            } else {
                                onOpen(.dictation)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                if let bundleID = item.bundleID,
                                   let icon = AppIconCache.icon(forBundleID: bundleID) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)

                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

/// A dictation or a note, flattened so one list can show both.
struct RecentItem: Identifiable {
    let id: String
    let date: Date
    let title: String
    let subtitle: String
    let symbol: String
    let isNote: Bool
    /// Set for dictations that went somewhere identifiable, so the row can carry that
    /// app's own icon instead of a generic microphone.
    var bundleID: String?
    /// The file itself, for notes, so the row can open it rather than the section.
    var note: NoteFile?

    static func merge(
        dictations: [DictationRecord], notes: [NoteFile], limit: Int
    ) -> [RecentItem] {
        let spoken = dictations.map {
            RecentItem(
                id: "d-\($0.id)",
                date: $0.date,
                title: $0.summary(limit: 70),
                subtitle: [
                    Self.when($0.date),
                    String(format: "%.0fs", $0.audioDuration),
                    $0.targetAppName,
                ].compactMap { $0 }.joined(separator: " · "),
                symbol: "mic.fill",
                isNote: false,
                bundleID: $0.targetBundleID
            )
        }

        let written = notes.map {
            RecentItem(
                id: "n-\($0.url.path)",
                date: $0.date,
                title: $0.title,
                subtitle: "\(Self.when($0.date)) · \(MeetingTranscript.clock($0.duration))",
                symbol: "text.document",
                isNote: true,
                note: $0
            )
        }

        return (spoken + written).sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    private static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
