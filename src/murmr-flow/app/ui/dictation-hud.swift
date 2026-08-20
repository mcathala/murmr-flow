import AppKit
import SwiftUI

/// The floating status pill shown while dictating.
///
/// Every window property here exists to stop the HUD from stealing focus:
///
/// - `.nonactivatingPanel` and never calling `makeKey` — activating would change the
///   frontmost app, and the paste would land in the HUD's app instead of the user's.
/// - `ignoresMouseEvents` — a stray click cannot focus it either.
/// - `canJoinAllSpaces` + `stationary` — it follows the user across Spaces instead of
///   being left behind on the desktop where dictation started.
@MainActor
final class DictationHUD {

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var recordingStartedAt: Date?

    private static let size = CGSize(width: 240, height: 52)
    /// Failures need room for a sentence, not just a word.
    private static let failureSize = CGSize(width: 360, height: 76)

    /// Called on stage transitions only. The elapsed counter is driven by this class's
    /// own ticker — routing it through the coordinator rebuilt the hosting view ten times
    /// a second for a label that only needs one decimal place.
    func update(stage: DictationCoordinator.Stage) {
        switch stage {
        case .idle:
            stopTicking()
            // Linger briefly so a fast dictation doesn't just flicker.
            scheduleHide(after: .milliseconds(600))
        case .failed:
            stopTicking()
            // Present before scheduling the hide: previously this only scheduled a hide,
            // so a dictation that failed before the HUD had appeared showed nothing at
            // all — the user pressed the key and got silence.
            hideTask?.cancel()
            present(stage: stage, elapsed: 0)
            scheduleHide(after: .seconds(4))
        case .recording:
            hideTask?.cancel()
            hideTask = nil
            recordingStartedAt = Date()
            present(stage: stage, elapsed: 0)
            startTicking()
        case .transcribing, .cleaning, .injecting:
            stopTicking()
            hideTask?.cancel()
            hideTask = nil
            present(stage: stage, elapsed: 0)
        }
    }

    func hide() {
        stopTicking()
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Ticker

    private func startTicking() {
        stopTicking()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let startedAt = self.recordingStartedAt else { return }
                self.present(stage: .recording, elapsed: Date().timeIntervalSince(startedAt))
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        recordingStartedAt = nil
    }

    // MARK: - Presentation

    private func present(stage: DictationCoordinator.Stage, elapsed: TimeInterval) {
        let view = HUDContent(stage: stage, elapsed: elapsed)
        let size = stage.detail == nil ? Self.size : Self.failureSize

        if let panel {
            (panel.contentView as? NSHostingView<HUDContent>)?.rootView = view
            // A failure needs more room than the status pill it replaces.
            if panel.frame.size != size {
                panel.setContentSize(size)
                position(panel, size: size)
            }
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: view)

        position(panel, size: size)
        // orderFrontRegardless, never makeKeyAndOrderFront: the latter would activate us.
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Bottom-centre of whichever screen holds the pointer, so on a multi-display setup
    /// it appears where the user is actually working.
    private func position(_ panel: NSPanel, size: CGSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.minY + 96
            )
        )
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

/// The pill itself.
private struct HUDContent: View {

    let stage: DictationCoordinator.Stage
    let elapsed: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.label)
                    .font(.subheadline.weight(.medium))
                if case .recording = stage {
                    Text("\(elapsed, format: .number.precision(.fractionLength(1)))s")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let detail = stage.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: stage.detail == nil ? 240 : 360, alignment: .leading)
        .frame(minHeight: 52)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch stage {
        case .recording:
            Image(systemName: "waveform")
                .foregroundStyle(.red)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .transcribing, .cleaning:
            ProgressView().controlSize(.small)
        case .injecting:
            Image(systemName: "text.cursor").foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}
