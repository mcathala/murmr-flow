import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// Renders the panel's states to PNGs so the layout can be *looked at* rather than
/// reasoned about. Writes to `MURMR_SNAPSHOT_DIR` when set; otherwise does nothing.
///
/// Every layout bug in this panel so far was found by eye and missed by arithmetic. The
/// numbers were right and the result was still wrong, which means the numbers were
/// answering the wrong question.
@MainActor
@Suite("Panel snapshots")
struct PanelSnapshotTests {

    /// Stand-in for the Dock, drawn at its real height on this Mac, so the panel's
    /// relationship to it is visible rather than inferred.
    private static let dockHeight: CGFloat = 41
    private static let windowGap: CGFloat = 10

    /// Tests do not go through `Info.plist`, so the bundled fonts have to be registered
    /// here. Without this every snapshot renders in the system fallback and quietly shows
    /// the wrong typeface — which is the exact failure the app guards against at launch.
    static let fontsRegistered: Bool = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // murmr-flow-tests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("resources/fonts")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return false }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return NSFontManager.shared.availableFontFamilies.contains(Theme.Face.ui)
    }()

    @Test("render every state")
    func render() throws {
        #expect(Self.fontsRegistered, "bundled fonts did not register — snapshots would lie")
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        // Every phase, in both modes where the mode changes what is drawn. The three
        // message states and the Notetaker's armed row are here because each one is a
        // layout the arithmetic cannot check: a row sized from a *measured* string is only
        // right if the string is allowed to take the width it was measured at, and a Text
        // that wraps instead is invisible to every assertion in this file.
        let cases: [(String, PanelModel.Phase, PanelModel.Mode)] = [
            ("resting", .resting, .dictation),

            ("armed", .armed, .dictation),
            ("armed-note", .armed, .note),
            ("dictating", .dictating, .dictation),
            ("meeting", .meeting, .note),

            ("working", .working("Cleaning up…"), .dictation),
            ("notice", .notice("Didn\u{2019}t hear anything"), .dictation),
            // The longest headline there is: if the message states fit anything, they fit
            // this, and the row is sized from it rather than clipping it.
            ("failed", .failed(.insertion), .dictation),
        ]

        for (name, phase, mode) in cases {
            let model = PanelModel()
            model.mode = mode
            model.set(phase)
            model.promptName = "Formal"
            // The case that used to be cut to fifteen characters and an ellipsis. The row
            // is sized from it now, so if it ever clips again it clips here first.
            model.promptDetail = "Mail"
            model.hotkeyLabel = "right ⌥"
            model.meetingHotkeyLabel = "⌥Space"
            model.hotkeyArmed = true
            model.targetAppName = "Brave Browser"
            model.targetAppIcon = AppIconCache.icon(forBundleID: "com.brave.Browser")
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
            model.elapsed = 64
            model.micLevel = 0.09        // speaking
            model.youLevel = 0.003       // a quiet room: should light nothing
            model.themLevel = 0.08       // audio actually playing

            let renderer = ImageRenderer(
                content: PanelView(model: model).environment(\.colorScheme, .dark)
            )
            renderer.scale = 2
            guard let panel = renderer.nsImage else { continue }

            let canvas = composite(panel: panel, size: model.size)
            guard let tiff = canvas.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }

            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try png.write(to: url)
        }
    }

    /// Places the panel where it really sits: horizontally centred, its bottom edge
    /// `windowGap` above the top of the Dock.
    private func composite(panel: NSImage, size: CGSize) -> NSImage {
        let width: CGFloat = 520
        let height: CGFloat = 190
        let canvas = NSImage(size: CGSize(width: width, height: height))

        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        // The Ink ground, so the glass has colour to refract. Against flat grey it is
        // only blur, which is exactly the mistake the palette exists to avoid.
        let ground = NSGradient(
            colors: [
                NSColor(srgbRed: 0.039, green: 0.118, blue: 0.220, alpha: 1),
                NSColor(srgbRed: 0.016, green: 0.063, blue: 0.122, alpha: 1),
            ]
        )
        ground?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 290)
        NSColor(srgbRed: 0.180, green: 0.525, blue: 0.757, alpha: 0.30).setFill()
        NSBezierPath(ovalIn: NSRect(x: -140, y: height - 150, width: 460, height: 340)).fill()

        // The Dock.
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: Self.dockHeight).fill()
        NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
        NSRect(x: 0, y: Self.dockHeight, width: width, height: 1).fill()

        // The panel's window bounds, so its own frame is visible too.
        let origin = CGPoint(
            x: (width - size.width) / 2,
            y: Self.dockHeight + Self.windowGap
        )
        NSColor(calibratedRed: 1, green: 0.3, blue: 0.3, alpha: 0.35).setFill()
        NSRect(origin: origin, size: size).frame(withWidth: 1)

        panel.draw(in: NSRect(origin: origin, size: size))
        return canvas
    }
}

/// The window must track the phase's size. Hover changes the phase from inside the view,
/// so nothing outside sees it unless the model says so — and a cluster laid out inside a
/// window still sized for the resting pill spills out of the bottom of it.
@MainActor
@Suite("Panel window")
struct PanelWindowTests {

    @Test("the window resizes for every phase")
    func windowFollowsPhase() {
        let panel = FloatingPanel()
        panel.present()

        for phase in [
            PanelModel.Phase.resting, .armed, .dictating, .meeting,
            .working("Cleaning up…"), .notice("Didn\u{2019}t hear anything"),
            .failed(.aiProvider), .failed(.insertion),
        ] {
            panel.model.set(phase)
            #expect(
                panel.windowSize == panel.model.size,
                "window \(String(describing: panel.windowSize)) != \(panel.model.size) for \(phase)"
            )
        }
    }

    @Test("hovering resizes without anyone calling apply")
    func hoverResizes() {
        let panel = FloatingPanel()
        panel.present()
        let resting = panel.windowSize

        // Exactly what the view does when the pointer arrives.
        panel.model.hover(true)

        #expect(panel.windowSize != resting)
        #expect(panel.windowSize == panel.model.size)
    }
}

/// The meters exist to catch a capture that started cleanly and recorded silence. If the
/// microphone's own noise floor lights a bar, they stop being believable and lose the only
/// job they have.
@Suite("Audio levels")
struct AudioLevelTests {

    @Test("a quiet room lights nothing")
    func quietRoomIsDark() {
        // Around -50 dBFS RMS, which is what a still room measures.
        for bar in 0..<3 {
            #expect(!AudioLevel.isLit(0.003, bar: bar))
        }
    }

    @Test("digital silence lights nothing")
    func silenceIsDark() {
        for bar in 0..<3 {
            #expect(!AudioLevel.isLit(0, bar: bar))
        }
    }

    @Test("conversational speech lights the meter")
    func speechShows() {
        // ~-21 dBFS RMS.
        #expect(AudioLevel.isLit(0.09, bar: 0))
        #expect(AudioLevel.isLit(0.09, bar: 1))
    }

    @Test("a room with a fan stays dark")
    func noisyRoomIsDark() {
        // ~-35 dBFS: the level that was lighting "You" while nobody spoke.
        #expect(!AudioLevel.isLit(0.018, bar: 0))
    }

    @Test("quiet speech still registers")
    func quietSpeechShows() {
        // ~-28 dBFS. The first bar has to catch this, or the meter under-reports someone
        // talking softly — which is the failure that would make it useless.
        #expect(AudioLevel.isLit(0.04, bar: 0))
        #expect(!AudioLevel.isLit(0.04, bar: 1))
    }

    @Test("the bars form a ramp rather than all lighting together")
    func ramp() {
        #expect((0..<3).allSatisfy { AudioLevel.isLit(0.2, bar: $0) })
        #expect(AudioLevel.isLit(0.09, bar: 1))
        #expect(!AudioLevel.isLit(0.09, bar: 2))
    }

    @Test("smoothing rises fast and falls slow")
    func attackAndRelease() {
        let rising = AudioLevel.smooth(0.0, towards: 0.5)
        let falling = AudioLevel.smooth(0.5, towards: 0.0)
        // A meter should reach most of the way up in one step and take several coming down.
        #expect(rising > 0.3)
        #expect(falling > 0.4)
    }

    @Test("the display scale is logarithmic, not linear")
    func normalisation() {
        // Linear amplitude would put -21 dBFS speech at 0.09 of full height — invisible.
        #expect(AudioLevel.normalised(0.09) > 0.5)
        #expect(AudioLevel.normalised(0.003) < 0.1)
        #expect(AudioLevel.normalised(0) == 0)
    }
}

/// Renders the insights breakdown, because "add the real logo" is a claim only a picture
/// can settle.
@MainActor
@Suite("Insights snapshot")
struct InsightsSnapshotTests {

    @Test("render where your words go")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let apps: [(String, String)] = [
            ("Cursor", "com.todesktop.230313mzl4w4u92"),
            ("Brave Browser", "com.brave.Browser"),
            ("Mail", "com.apple.mail"),
            ("Gone", "com.example.uninstalled"),
        ]

        var records: [DictationRecord] = []
        for (index, app) in apps.enumerated() {
            records.append(
                DictationRecord(
                    date: calendar.date(byAdding: .day, value: -index, to: now)!,
                    audioDuration: 12,
                    rawText: "",
                    finalText: Array(repeating: "word", count: 40 - index * 9)
                        .joined(separator: " "),
                    targetAppName: app.0,
                    targetBundleID: app.1
                )
            )
        }

        let insights = Insights.compute(from: records, calendar: calendar, now: now)
        let view = InsightsGrid(insights: insights, typingSpeed: 40, windowDays: 7)
            .frame(width: 620)
            .padding(16)
            .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("insights.png")
        )
    }
}

@MainActor
@Suite("App icons")
struct AppIconTests {

    @Test("no bundle identifier means no icon")
    func missingIdentifier() {
        #expect(AppIconCache.icon(forBundleID: nil) == nil)
        #expect(AppIconCache.icon(forBundleID: "") == nil)
    }

    @Test("an app that isn't installed resolves to nothing, and stays that way")
    func uninstalled() {
        let id = "com.example.definitely-not-installed"
        #expect(AppIconCache.icon(forBundleID: id) == nil)
        // Cached as a miss rather than retried on every redraw.
        #expect(AppIconCache.icon(forBundleID: id) == nil)
    }
}

/// Home's summary strip, so the three-number row can be judged by eye.
@MainActor
@Suite("Home summary snapshot")
struct HomeSummarySnapshotTests {

    @Test("render the summary strip")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        let records = (0..<4).map { offset in
            DictationRecord(
                date: calendar.date(byAdding: .day, value: -offset, to: now)!,
                audioDuration: 14,
                rawText: "",
                finalText: Array(repeating: "word", count: 60).joined(separator: " "),
                targetAppName: "Brave Browser",
                targetBundleID: "com.brave.Browser"
            )
        }
        let insights = Insights.compute(from: records, calendar: calendar, now: now)

        let view = VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Recents")
            Card {
                Text("▤ Pricing call with Léa").font(.callout)
            }
            Card {
                HStack(spacing: 0) {
                    summaryStat("\(insights.wordsDictated)", "words this week")
                    summaryDivider
                    summaryStat(Insights.shortDuration(insights.timeSaved), "saved")
                    summaryDivider
                    summaryStat("\(insights.streakDays)", "day streak")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 560)
        .padding(16)
        .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("home-summary.png")
        )
    }

    private func summaryStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 92, alignment: .leading)
    }

    private var summaryDivider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 26).padding(.trailing, 16)
    }
}

/// Renders the two record cards one above the other.
///
/// The Notetaker card was added as a copy of the Dictation card and drifted immediately — wrong
/// button colour, wrong fonts, wrong width — and none of that showed up in a diff. They
/// share `RecordCard` now, and this is what makes "the same" checkable by eye rather than
/// by reading two files.
@MainActor
@Suite("Record card snapshot")
struct RecordCardSnapshotTests {

    @Test("render both modes' record cards together")
    func render() throws {
        #expect(
            PanelSnapshotTests.fontsRegistered,
            "bundled fonts did not register — snapshots would lie"
        )
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let view = VStack(spacing: 14) {
            RecordCard(
                title: "Hold right ⌥ anywhere",
                subtitle: "Hold the key while you speak.",
                buttonTitle: "Dictate",
                buttonSymbol: "mic.fill",
                action: {}
            ) {
                Text("Default").font(.body).foregroundStyle(Theme.Palette.gold)
            }

            RecordCard(
                title: "Ready to record",
                subtitle: "Your microphone is \u{201C}You\u{201D}; everything this Mac "
                    + "plays is \u{201C}Them\u{201D}.",
                buttonTitle: "Record",
                buttonSymbol: "record.circle.fill",
                action: {}
            ) {
                Text("Meeting").font(.body).foregroundStyle(Theme.Palette.gold)
            }

            RecordCard(
                title: "Recording — 4:12",
                subtitle: "Your microphone is \u{201C}You\u{201D}; everything this Mac "
                    + "plays is \u{201C}Them\u{201D}.",
                buttonTitle: "Stop",
                buttonSymbol: "stop.fill",
                isActive: true,
                action: {}
            ) {
                LevelMeter(label: "You", level: 0.6)
                LevelMeter(label: "Them", level: 0.1)
                Button("Discard") {}.controlSize(.small)
            }
        }
        .frame(width: 680)
        .padding(20)
        .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("record-cards.png")
        )
    }
}
