import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MurmrFlow

/// Selection had to be reimplemented because `List`'s highlight is `controlAccentColor` and
/// no app can recolour it. Reimplementing it means the behaviours people already expect —
/// plain click, ⌘, ⇧, arrow keys — are now this app's job to get right.
@Suite("Row selection")
struct RowSelectionTests {

    private let items = ["a", "b", "c", "d", "e"]

    @Test("a plain click replaces the selection")
    func plainClick() {
        var selection: Set<String> = ["a", "b"]
        var anchor: String? = "a"

        RowClick.apply("d", in: items, selection: &selection, anchor: &anchor, modifiers: [])

        #expect(selection == ["d"])
        #expect(anchor == "d")
    }

    @Test("command toggles one row without disturbing the rest")
    func commandClick() {
        var selection: Set<String> = ["a", "c"]
        var anchor: String? = "c"

        RowClick.apply("e", in: items, selection: &selection, anchor: &anchor, modifiers: [.command])
        #expect(selection == ["a", "c", "e"])

        RowClick.apply("a", in: items, selection: &selection, anchor: &anchor, modifiers: [.command])
        #expect(selection == ["c", "e"])
    }

    @Test("shift extends from the anchor, in either direction")
    func shiftClick() {
        var selection: Set<String> = ["b"]
        var anchor: String? = "b"

        RowClick.apply("d", in: items, selection: &selection, anchor: &anchor, modifiers: [.shift])
        #expect(selection == ["b", "c", "d"])

        // Backwards over the anchor, which is the case an off-by-one usually breaks.
        RowClick.apply("a", in: items, selection: &selection, anchor: &anchor, modifiers: [.shift])
        #expect(selection == ["a", "b"])
    }

    /// ⇧-click with nothing selected yet has no anchor to extend from.
    @Test("shift with no anchor selects just the row")
    func shiftWithoutAnchor() {
        var selection: Set<String> = []
        var anchor: String?

        RowClick.apply("c", in: items, selection: &selection, anchor: &anchor, modifiers: [.shift])
        #expect(selection == ["c"])
        #expect(anchor == "c")
    }

    @Test("arrows move one row and stop at the ends")
    func arrows() {
        var selection: Set<String> = ["c"]
        var anchor: String? = "c"

        RowClick.move(.down, in: items, selection: &selection, anchor: &anchor)
        #expect(selection == ["d"])
        RowClick.move(.down, in: items, selection: &selection, anchor: &anchor)
        #expect(selection == ["e"])
        // Already at the bottom — it should stay, not wrap or crash.
        RowClick.move(.down, in: items, selection: &selection, anchor: &anchor)
        #expect(selection == ["e"])

        for _ in 0..<10 {
            RowClick.move(.up, in: items, selection: &selection, anchor: &anchor)
        }
        #expect(selection == ["a"])
    }

    @Test("an arrow on an empty list does nothing")
    func arrowsOnEmpty() {
        var selection: Set<String> = []
        var anchor: String?
        RowClick.move(.down, in: [], selection: &selection, anchor: &anchor)
        #expect(selection.isEmpty)
    }

    /// Left and right are handed to the list for other purposes; they must not move the
    /// selection sideways through the rows.
    @Test("left and right are ignored")
    func horizontalIgnored() {
        var selection: Set<String> = ["c"]
        var anchor: String? = "c"
        RowClick.move(.left, in: items, selection: &selection, anchor: &anchor)
        RowClick.move(.right, in: items, selection: &selection, anchor: &anchor)
        #expect(selection == ["c"])
    }
}

@MainActor
@Suite("Sidebar snapshot")
struct SidebarSnapshotTests {

    @Test("render both levels, selected and not")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        // The app's own labels, not stand-ins — the point is to catch a label that does not
        // fit. "Voice transcription" truncated to "Voice transcri…" in the running app and
        // a snapshot with invented rows would never have shown it.
        //
        // Both states, because Settings is pinned to the bottom and unfolds in place: the
        // closed column and the open one, and either could be the one that overflows.
        let top: [(String, String)] = MainWindow.Route.top.map { ($0.label, $0.symbol) }
        let settings: [(String, String)] = SettingsPane.allCases.map { ($0.label, $0.symbol) }

        func row(
            _ label: String, _ symbol: String, selected: Bool,
            trailing: String? = nil, isTitle: Bool = false
        ) -> some View {
            SelectableRow(isSelected: selected) {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5))
                        .frame(width: 17)
                        .foregroundStyle(selected ? Theme.Palette.gold : Theme.Palette.muted)
                    Text(label)
                        .font(isTitle ? Theme.Text.bodyStrong : Theme.Text.body)
                        .foregroundStyle(
                            selected || isTitle ? Theme.Palette.text : Theme.Palette.muted
                        )
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let trailing {
                        Image(systemName: trailing)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.faint)
                    }
                }
            }
        }

        func column(@ViewBuilder _ rows: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                // The real header, at its own height, so the mark is seen here too. It no
                // longer sits in the title bar's row, so nothing is imposed on it here.
                SidebarHeader()
                rows()
            }
                // The sidebar's default width, so a label that does not fit shows here too.
                .frame(width: 198)
                .padding(.vertical, 8)
                .glassColumn(.thick)
        }

        let view = HStack(spacing: 12) {
            column {
                ForEach(top, id: \.0) { row($0.0, $0.1, selected: $0.0 == "Dictation") }
                Spacer(minLength: 40)
                row("Settings", "gearshape", selected: false, trailing: "chevron.up")
            }
            column {
                ForEach(top, id: \.0) { row($0.0, $0.1, selected: false) }
                Spacer(minLength: 40)
                ForEach(settings, id: \.0) {
                    row($0.0, $0.1, selected: $0.0 == "AI clean-up")
                }
                row(
                    "Settings", "gearshape", selected: false,
                    trailing: "chevron.down", isTitle: true
                )
            }
        }
        .frame(height: 420)
        .background(InkGround())

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar.png")
        )
    }
}
