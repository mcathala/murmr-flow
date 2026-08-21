import SwiftUI

/// Home, in two parts: what you made, and what that adds up to.
///
/// It used to be a lobby whose only claim was a Start button. Start moved to the toolbar,
/// where it's available from every section — which freed Home to be the two things worth
/// opening a window for.
struct HomeView: View {

    let services: AppServices
    let onOpen: (MainWindow.Route) -> Void

    var body: some View {
        PaneScroll {
            status
            if let trouble { WarningRow(message: trouble.message, action: trouble.action) }

            SectionLabel(title: "Recents")
            recents

            SectionLabel(title: "Insights")
            InsightsGrid(insights: insights, typingSpeed: Insights.defaultTypingWordsPerMinute)
        }
        .onAppear { services.notes.reload() }
    }

    // MARK: - Status

    /// The two halves of the pipeline, and nothing else. A dead hotkey is a *problem*, so
    /// it belongs in the warning below rather than sitting here as a status.
    private var status: some View {
        HStack(spacing: 8) {
            StatusChip(title: "Voice engine", level: voiceLevel)
            StatusChip(title: "AI clean-up", level: cleanupLevel)
            Spacer(minLength: 0)
        }
    }

    private var voiceLevel: StatusChip.Level {
        switch services.dictation.voiceTest {
        case .heard: .ok
        case .failed, .silent: .bad
        case .idle, .running:
            // Loaded is not the same as proven. Until the test has run, the honest
            // reading is "ready to try", not "working".
            services.dictation.models.state == .ready ? .waiting : .bad
        }
    }

    private var cleanupLevel: StatusChip.Level {
        guard services.settings.cleanupEnabled else { return .waiting }
        switch services.dictation.providerTest {
        case .working: return .ok
        case .failed: return .bad
        case .idle, .running: return services.settings.hasAPIKey ? .waiting : .bad
        }
    }

    private var trouble: (message: String, action: (title: String, run: () -> Void))? {
        if services.permissions.accessibility != .granted {
            return (
                "Accessibility is off, so your hotkey won't fire.",
                ("Open Settings", { services.permissions.openAccessibilitySettings() })
            )
        }
        if !services.dictation.hotkeyActive {
            return (
                "The key watcher isn't running. Restart Murmr Flow.",
                ("Quit", { NSApplication.shared.terminate(nil) })
            )
        }
        if case .failed(let message) = services.dictation.models.state {
            return (message, ("Retry", { Task { await services.dictation.warmUp() } }))
        }
        return nil
    }

    // MARK: - Recents

    private var insights: Insights {
        Insights.compute(from: services.history.dictations)
    }

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
                Text("Hold your hotkey and speak, or start a meeting from the toolbar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Card {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Button {
                            onOpen(item.isNote ? .notes : .dictaphone)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
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
                isNote: false
            )
        }

        let written = notes.map {
            RecentItem(
                id: "n-\($0.url.path)",
                date: $0.date,
                title: $0.title,
                subtitle: "\(Self.when($0.date)) · \(MeetingTranscript.clock($0.duration))",
                symbol: "text.document",
                isNote: true
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
