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

            SectionLabel(title: "Recents")
            recents

            if !history.isEmpty {
                Button {
                    onOpen(.insights)
                } label: {
                    Label("See your insights", systemImage: "chart.bar")
                }
                .controlSize(.small)
            }
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
        let speech = services.speech
        switch speech.verification(for: speech.activeModel) {
        case .working: return .ok
        case .failed: return .bad
        case .untested:
            // Loaded is not the same as proved. Until the test has run, the honest
            // reading is "ready to try", not "working".
            return services.dictation.models.state == .ready ? .waiting : .bad
        }
    }

    private var cleanupLevel: StatusChip.Level {
        guard services.settings.cleanupEnabled else { return .waiting }
        let providers = services.providers
        switch providers.state(for: providers.activeID).verification {
        case .working: return .ok
        case .failed: return .bad
        // Configured but never exercised is amber, not green: a pasted key is not a
        // working key, and this chip is the one place that claim is made.
        case .untested: return providers.isUsable(providers.activeID) ? .waiting : .bad
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
