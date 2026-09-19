import AppKit
import Observation
import SwiftUI

/// When the section menu is out, and the waiting either side of it.
///
/// The waiting is the whole design. The name sits at the top-left of the content, in the
/// path between the traffic lights and the window's left edge — so a pointer merely
/// travelling somewhere passes over it. Opening on contact would mean the menu appearing
/// on trips that had nothing to do with it. Opening after a pause means resting on the
/// name opens it and crossing it does not.
///
/// Its own object rather than `@State` in a view, because the name and the menu are two
/// views and each has to be able to cancel what the other started.
@MainActor
@Observable
final class SectionMenu {

    /// Long enough that crossing the title bar never opens it, short enough that resting
    /// on the name does not feel like waiting. Tuned in the prototype before it was built.
    static let openDelay = Duration.milliseconds(250)

    /// The pointer has to cross the gap between the name and the menu below it. Without
    /// the wait the menu shuts in that gap, under the pointer on its way in.
    static let closeDelay = Duration.milliseconds(180)

    private(set) var isOpen = false

    private var openWork: Task<Void, Never>?
    private var closeWork: Task<Void, Never>?

    /// The pointer has arrived on the name. Nothing shows yet.
    func arm() {
        cancelClose()
        cancelOpen()
        openWork = Task { [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled else { return }
            self?.isOpen = true
        }
    }

    /// The pointer has left the name, or something else has claimed it.
    func disarm() {
        cancelOpen()
    }

    /// The pointer is on the menu itself; whatever close was pending is off.
    func keepOpen() {
        cancelClose()
    }

    func scheduleClose() {
        cancelOpen()
        cancelClose()
        closeWork = Task { [weak self] in
            try? await Task.sleep(for: Self.closeDelay)
            guard !Task.isCancelled else { return }
            self?.isOpen = false
        }
    }

    /// Now, with no wait: a section was chosen, or the peek took over.
    func close() {
        cancelOpen()
        cancelClose()
        isOpen = false
    }

    private func cancelOpen() {
        openWork?.cancel()
        openWork = nil
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}

/// The sections, under the name at the top of the content, while the sidebar is away.
///
/// Drawn by the app rather than handed to `NSMenu`. A system menu cannot be recoloured —
/// the same reason `SelectableRow` exists — so it would have arrived grey in the middle of
/// a navy and gold window. The cost is the conventions that come free with a real menu,
/// type-ahead among them.
struct SectionMenuView: View {

    let services: AppServices

    static let width: CGFloat = 186

    var body: some View {
        VStack(spacing: 2) {
            ForEach(MainWindow.Route.top, id: \.self) { route in
                row(route.label, symbol: route.symbol, isSelected: services.route == route) {
                    services.route = route
                    services.sectionMenu.close()
                }
            }

            // Settings is a level rather than a section, so it sits under a rule with its
            // shortcut beside it. It opens the pane you were last in, which is what
            // `openSettings()` has always done.
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 1)
                .padding(.horizontal, 3)
                .padding(.vertical, 4)

            row(
                "Settings", symbol: "gearshape", isSelected: services.route.isSettings,
                trailing: "⌘,"
            ) {
                services.openSettings()
                services.sectionMenu.close()
            }
        }
        .padding(5)
        .frame(width: Self.width)
        .glass(.thick, radius: 11)
        .onHover { hovering in
            if hovering {
                services.sectionMenu.keepOpen()
            } else {
                services.sectionMenu.scheduleClose()
            }
        }
    }

    private func row(
        _ label: String,
        symbol: String,
        isSelected: Bool,
        trailing: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        SelectableRow(isSelected: isSelected, radius: 8) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? Theme.Palette.gold : Theme.Palette.muted)
                Text(label)
                    .font(Theme.Text.body)
                    .foregroundStyle(isSelected ? Theme.Palette.text : Theme.Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(Theme.Text.mono)
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        }
        .onTapGesture(perform: action)
    }
}
