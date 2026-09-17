import SwiftUI

/// The menu bar: the only surface that is always there.
///
/// The app has no Dock icon, so when the window is closed this is the whole interface —
/// and it is the only sign that the Notetaker is still recording after the panel has been
/// hidden. So it carries live state and the two jobs you can't reach otherwise, then
/// hands off.
///
/// **Drawn like the sidebar, not like a form.** The first version stacked three bordered
/// buttons and repeated the app's name under the icon that already says it. Now the header
/// is the state, led by the mark in the state's colour; every action is a row with the
/// symbol the sidebar uses for the same thing; and a state that needs fixing is a row you
/// can click, not a line of orange text.
///
/// This view reads the services and decides; `MenuBarPanel` draws. The split is what lets
/// the panel be rendered in a snapshot with made-up state, since `AppServices` cannot be.
struct MenuBarContent: View {

    let services: AppServices

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanel(
            status: status,
            actions: actions,
            notes: Array(services.notes.notes.prefix(3)),
            // In the app, on the note itself. It opened in whatever editor the Mac keeps
            // for Markdown, which is a strange answer from an app that shows notes.
            openNote: { note in
                services.open(note: note)
                openWindow(id: MurmrFlowApp.mainWindowID)
            },
            openWindow: { openWindow(id: MurmrFlowApp.mainWindowID) },
            openSettings: {
                services.openSettings()
                openWindow(id: MurmrFlowApp.mainWindowID)
            },
            quit: { NSApplication.shared.terminate(nil) }
        )
        .onAppear { services.notes.reload() }
    }

    // MARK: - Deciding

    private var status: MenuBarPanel.Status {
        let dictation = services.dictation
        let meetings = services.meetings
        let permissions = services.permissions

        // The Notetaker outranks everything: it is the one thing that can be running with
        // no other sign of it on screen.
        if meetings.stage.isRecording {
            return .init(
                tone: .recording,
                title: "Notetaker recording",
                detail: MeetingTranscript.clock(meetings.elapsed),
                levels: (meetings.youLevel, meetings.themLevel)
            )
        }
        if dictation.stage.isRecording {
            return .init(tone: .recording, title: dictation.stage.label, detail: "Dictation")
        }
        if dictation.stage.isBusy {
            return .init(tone: .attention, title: dictation.stage.label, detail: "Dictation")
        }
        if !permissions.allGranted {
            let missing = [
                permissions.microphone == .granted ? nil : "Microphone",
                permissions.accessibility == .granted ? nil : "Accessibility",
            ].compactMap { $0 }
            let verb = missing.count == 1 ? "is" : "are"
            // The chevron says "click"; spelling out where it goes did not fit the row.
            return .init(
                tone: .attention,
                title: "Permissions needed",
                detail: "\(missing.joined(separator: " and ")) \(verb) off",
                fix: {
                    services.openSettings(.privacyData)
                    openWindow(id: MurmrFlowApp.mainWindowID)
                }
            )
        }
        if !dictation.hotkeyActive {
            return .init(
                tone: .dimmed,
                title: "Hotkey not active",
                detail: "Start a dictation from the row below"
            )
        }
        return .init(
            tone: .ready,
            title: "Ready",
            detail: "\(dictation.settings.hotkeyPhrase) to dictate"
        )
    }

    /// Dictation first, then the Notetaker — the sidebar's order and the sidebar's names.
    /// Whichever is running turns into its own Stop and hides the other.
    private var actions: [MenuBarPanel.Action] {
        let dictation = services.dictation
        let meetings = services.meetings

        if meetings.stage.isRecording {
            return [
                .init(
                    title: "Stop Notetaker", symbol: "text.document", tone: .recording,
                    trailing: MeetingTranscript.clock(meetings.elapsed)
                ) { meetings.toggle() },
            ]
        }
        if dictation.stage.isRecording {
            return [
                .init(title: "Stop dictation", symbol: "mic", tone: .recording) {
                    Task { await dictation.endDictation() }
                },
            ]
        }
        return [
            // Click is a toggle where the key is a hold: a second way in for someone whose
            // key is not set, not granted, or simply not to hand.
            .init(title: "Dictation", symbol: "mic", isEnabled: !dictation.stage.isBusy) {
                dictation.beginDictation()
            },
            .init(title: "Notetaker", symbol: "text.document") { meetings.toggle() },
        ]
    }
}

/// The menu as drawn. Everything it shows is handed in, so it can be looked at with any
/// state — see the snapshot test.
struct MenuBarPanel: View {

    /// What the header says. The mark and the title wear the tone.
    struct Status {
        enum Tone { case ready, dimmed, attention, recording }
        var tone: Tone
        var title: String
        var detail: String
        /// The you/them levels while the Notetaker records: drawn as two tiny meters.
        var levels: (you: Float, them: Float)?
        /// When set, the header is a row that does this — the way past the problem.
        var fix: (() -> Void)?

        init(
            tone: Tone, title: String, detail: String,
            levels: (you: Float, them: Float)? = nil, fix: (() -> Void)? = nil
        ) {
            self.tone = tone
            self.title = title
            self.detail = detail
            self.levels = levels
            self.fix = fix
        }
    }

    struct Action: Identifiable {
        var title: String
        var symbol: String
        var tone: Status.Tone = .ready
        var isEnabled = true
        var trailing: String?
        var run: () -> Void
        var id: String { title }

        init(
            title: String, symbol: String, tone: Status.Tone = .ready, isEnabled: Bool = true,
            trailing: String? = nil, run: @escaping () -> Void
        ) {
            self.title = title
            self.symbol = symbol
            self.tone = tone
            self.isEnabled = isEnabled
            self.trailing = trailing
            self.run = run
        }
    }

    let status: Status
    let actions: [Action]
    let notes: [NoteFile]
    let openNote: (NoteFile) -> Void
    let openWindow: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void

    static let width: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            header
            separator

            ForEach(actions) { action in
                MenuRow(
                    action.title, symbol: action.symbol, tone: action.tone,
                    trailing: action.trailing, action: action.run
                )
                .disabled(!action.isEnabled)
            }

            if !notes.isEmpty {
                separator
                SectionLabel(title: "Recent notes")
                    .padding(.horizontal, 9)
                    .padding(.top, 6)
                    .padding(.bottom, 3)
                ForEach(notes) { note in
                    MenuRow(
                        note.title, symbol: nil, trailing: Self.relative(note.date)
                    ) { openNote(note) }
                }
            }

            separator
            MenuRow("Open Murmr Flow", symbol: "macwindow", action: openWindow)
            MenuRow("Settings…", symbol: "gearshape", trailing: "⌘,", action: openSettings)
            MenuRow("Quit", symbol: "power", trailing: "⌘Q", action: quit)
        }
        .padding(8)
        .frame(width: Self.width)
        .font(Theme.Text.body)
        .foregroundStyle(Theme.Palette.text)
        // Nearly solid over the system's material, so the popover is the app's navy with
        // a trace of what is behind it — the same weight as the floating panel.
        .background(Theme.Palette.solid.opacity(0.94))
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let fix = status.fix {
            Button(action: fix) { headerRow(chevron: true) }
                .buttonStyle(MenuRowStyle())
        } else {
            headerRow(chevron: false)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
        }
    }

    private func headerRow(chevron: Bool) -> some View {
        HStack(spacing: 9) {
            MurmrMarkShape()
                .fill(Self.colour(status.tone))
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(Theme.Text.bodyStrong)
                    .foregroundStyle(Self.colour(status.tone, text: true))
                HStack(spacing: 5) {
                    Text(status.detail)
                    if let levels = status.levels {
                        Text("· You")
                        Ticks(level: levels.you)
                        Text("· Them")
                        Ticks(level: levels.them)
                    }
                }
                .font(Theme.Text.small)
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.faint)
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
    }

    static func colour(_ tone: Status.Tone, text: Bool = false) -> Color {
        switch tone {
        case .ready: text ? Theme.Palette.text : Theme.Palette.gold
        case .dimmed: text ? Theme.Palette.text : Theme.Palette.gold.opacity(0.45)
        case .attention: Theme.Palette.gold
        case .recording: Theme.Palette.danger
        }
    }

    /// "2 h", "yest.", "3 d" — the width of a shortcut, so the column of notes lines up
    /// with the column of shortcuts below it.
    static func relative(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) m" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) h" }
        if Calendar.current.isDateInYesterday(date) { return "yest." }
        if seconds < 7 * 86400 { return "\(Int(seconds / 86400)) d" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// One row: a symbol in the sidebar's fixed slot, a label, and a shortcut or a time on the
/// right. Lights on hover, the way a menu item does.
private struct MenuRow: View {
    let title: String
    let symbol: String?
    var tone: MenuBarPanel.Status.Tone = .ready
    var trailing: String?
    let action: () -> Void

    init(
        _ title: String, symbol: String?, tone: MenuBarPanel.Status.Tone = .ready,
        trailing: String? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5))
                        // The sidebar's slot, so labels here line up the way they do there.
                        .frame(width: 17)
                        .foregroundStyle(iconColour)
                } else {
                    Color.clear.frame(width: 17, height: 1)
                }
                Text(title)
                    .foregroundStyle(tone == .recording ? Theme.Palette.danger : Theme.Palette.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(Theme.Text.mono)
                        .foregroundStyle(tone == .recording ? Theme.Palette.danger : Theme.Palette.faint)
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private var iconColour: Color {
        tone == .recording ? Theme.Palette.danger : Theme.Palette.muted
    }
}

/// Hover lights the row; pressing lights it a little more; disabled fades the lot.
private struct MenuRowStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
    }
}

/// Four bars of level, small enough to sit in a line of text. Enough to say "still
/// hearing you" and "still hearing them"; the panel has the real meters.
private struct Ticks: View {
    let level: Float
    private static let falloff: [CGFloat] = [0.5, 1, 0.8, 0.35]

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<Self.falloff.count, id: \.self) { index in
                Capsule()
                    .fill(Theme.Palette.danger)
                    .frame(
                        width: 2,
                        height: 3 + 7 * CGFloat(AudioLevel.normalised(level)) * Self.falloff[index]
                    )
            }
        }
        .frame(height: 10, alignment: .bottom)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
