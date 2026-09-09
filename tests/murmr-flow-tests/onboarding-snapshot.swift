import AppKit
import SwiftUI
import Testing

@testable import MurmrFlow

/// Renders the first-launch screens at the window's size so the layout can be looked at
/// without revoking this Mac's permissions to get the real thing back.
///
/// The steps rendered are whichever this machine would show: a step whose condition already
/// holds for the test process is skipped, exactly as it would be in the app. The flow is
/// never finished here — that would write `onboarding.completed` into the test runner's
/// defaults and every later run would render nothing.
///
/// Same caveat as the other snapshots: `ImageRenderer` cannot draw AppKit-backed controls,
/// so buttons and the text field may come out as placeholders. Layout, wording and state
/// are what this checks; the controls have to be looked at in the running app.
@MainActor
@Suite("Onboarding snapshot")
struct OnboardingSnapshotTests {

    @Test("render every step this machine would show")
    func render() throws {
        #expect(
            PanelSnapshotTests.fontsRegistered,
            "bundled fonts did not register — snapshots would lie"
        )
        guard let directory = ProcessInfo.processInfo.environment["MURMR_SNAPSHOT_DIR"] else {
            return
        }

        let services = AppServices.shared
        let flow = services.onboarding

        while true {
            try write(
                OnboardingView(services: services),
                as: "onboarding-\(flow.position)-\(flow.step)",
                in: directory
            )
            // The pause after declining the AI, then back to the page it interrupts. Only
            // the first decline is driven: the second one can finish the flow, and a
            // finished flow would write completion into the runner's defaults.
            if flow.step == .connectAI {
                flow.declineAI()
                try write(
                    OnboardingView(services: services),
                    as: "onboarding-\(flow.position)-\(flow.step)",
                    in: directory
                )
                flow.back()
            }
            guard flow.step != .tryIt else { break }
            flow.advance()
        }
    }

    private func write(_ content: some View, as name: String, in directory: String) throws {
        let view = content
            .frame(width: 1000, height: 650)
            .background(InkGround())
            .font(Theme.Text.body)
            .foregroundStyle(Theme.Palette.text)
            .tint(Theme.Palette.gold)

        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return }

        try png.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        )
    }
}
