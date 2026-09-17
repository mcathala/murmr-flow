import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// The reading pane as it shows a note the Notetaker wrote: what was kept, then what was
/// said. Rendered so it can be looked at — the note was invisible in this pane for a whole
/// build, and arithmetic would not have caught that either.
@MainActor
@Suite("Note reading pane")
struct NoteSnapshotTests {

    @Test("render a written note above its transcript")
    func render() throws {
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }
        _ = PanelSnapshotTests.fontsRegistered

        let file = """
            ---
            title: Murmr Flow — what shipped, and what the note should say
            date: 2026-09-16T15:42:00+02:00
            duration: 842
            cleanup: Notes
            note: Summary
            ---

            # Murmr Flow — what shipped, and what the note should say

            ### Where the app stands
            - Speech-to-text runs on the machine with Parakeet, about 600 MB, covering 25 \
            European languages plus Japanese.
            - The style a dictation uses can follow the app in front, or a key of its own.

            ### Why a transcript was not enough
            - Forty turns is a faithful record nobody rereads.
            - The note keeps every figure exactly. Rounding $5.84 to "about six dollars" is \
            worse than the transcript it replaced.

            ### Next steps
            - [ ] Record a real meeting and check the note reads better (You)
            - [ ] Look at whether an hour fits in one request (Them)

            ## Transcript

            **You** · `0:00`

            Right, can you hear me? Good. So I wanted to go through where Murmr Flow \
            actually is.

            **Them** · `0:11`

            Yeah, go for it. I've been using it for dictation for about two weeks now.
            """

        let (_, body) = NoteFile.split(file)
        let view = VStack(alignment: .leading, spacing: 0) {
            NoteSummaryView(lines: NoteFile.summary(in: body))
            SectionLabel(title: "Transcript")
                .padding(.top, 20)
                .padding(.bottom, 10)
            TranscriptView(turns: NoteFile.turns(in: body))
        }
        .frame(width: 620)
        .padding(24)
        .background(Theme.Palette.deep)

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("note-reading.png")
        )
    }
}
