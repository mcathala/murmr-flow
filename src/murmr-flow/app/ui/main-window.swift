import SwiftUI

/// The app window: a sidebar and one section at a time.
///
/// Settings lives **in** the sidebar, as a level you enter, rather than in a separate
/// Settings window. One window means one place to be, and ⌘, enters that level rather
/// than opening a second scene.
struct MainWindow: View {

    let services: AppServices

    /// Both levels of navigation in one value, so selection is a single source of truth
    /// and the keyboard shortcut can move it from outside the view.
    enum Route: Hashable {
        case home
        case dictation
        case notetaker
        case insights
        case settings(SettingsPane)

        static let top: [Route] = [.home, .dictation, .notetaker, .insights]

        var label: String {
            switch self {
            case .home: "Home"
            case .dictation: "Dictation"
            case .notetaker: "Notetaker"
            case .insights: "Insights"
            case .settings(let pane): pane.label
            }
        }

        var symbol: String {
            switch self {
            case .home: "square.grid.2x2"
            case .dictation: "mic"
            case .notetaker: "text.document"
            case .insights: "chart.bar"
            case .settings(let pane): pane.symbol
            }
        }

        /// Which of the sidebar's two levels this route belongs to.
        var isSettings: Bool {
            if case .settings = self { return true }
            return false
        }
    }

    static let minSize = CGSize(width: 900, height: 600)

    /// A fixed column, not a `NavigationSplitView`.
    ///
    /// The split view brought nothing this window uses and a queue of faults with it. It
    /// synthesises a toolbar, and a toolbar with items carries a clipped-items indicator —
    /// the round `»` that flashed at the top right whenever the column's width changed. It
    /// draws its own sidebar toggle, which is not a toolbar item at all but SwiftUI's own
    /// view inside the column, so emptying the toolbar never removed it. It persists a
    /// collapsed state, so the app could open with no navigation at all. And nothing turns
    /// any of that off: `.toolbar(removing: .sidebarToggle)`,
    /// `.toolbar(.hidden, for: .windowToolbar)`, `CommandGroup(replacing: .sidebar) {}`, a
    /// constant `columnVisibility` binding and `NSSplitViewItem.canCollapse = false` were
    /// each measured against the running window and each did nothing.
    ///
    /// An `HStack` has no toolbar, draws no controls of its own, and remembers nothing. The
    /// sidebar is this app's navigation and is always meant to be there, so a layout that
    /// cannot take it away is the right shape.
    static let sidebarWidth: CGFloat = 198

    var body: some View {
        ZStack {
            // One ground behind everything, reaching every edge of the window — the title
            // bar's row included.
            //
            // A sibling in a stack rather than a `.background`. `InkGround` ignores the
            // safe area and always has, but as the *root view's* background it was laid
            // out inside that safe area with no room to expand past it, so the strip
            // beside the traffic lights was left to the window's own colour. A sibling in
            // a stack has the room.
            //
            // This is not what cured the grey band across the top — that was AppKit
            // drawing the title bar over everything, and `.windowStyle(.hiddenTitleBar)`
            // in `MurmrFlowApp` is what answers it. The ground should reach the window's
            // edges either way.
            InkGround()
                .ignoresSafeArea()

            Group {
                // First launch takes the whole window. The sidebar is navigation, and
                // there is nowhere to navigate to until the app can hear you.
                if services.onboarding.isComplete {
                    shell.transition(.opacity)
                } else {
                    OnboardingView(services: services).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: services.onboarding.isComplete)
        }
        // Zero-size, draws nothing: it is here to hear which window it ends up in.
        .background(WindowChrome().frame(width: 0, height: 0))
        .font(Theme.Text.body)
        .foregroundStyle(Theme.Palette.text)
        .tint(Theme.Palette.gold)
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }

    /// Leaving the card does not put it away at once — see `hidePeek()`.
    @State private var closeWork: Task<Void, Never>?

    /// Whether the peek card is out. It lives in `AppServices` rather than here because
    /// the name in the title bar has to know about it — see `SectionMenu`.
    private var isPeeking: Bool { services.isPeeking }

    /// How much room the title bar's row takes, read from the window rather than assumed.
    ///
    /// Everything at the top of this window hangs off this one number: the brand row's
    /// clearance, where the peek card starts, where the section menu drops to. They were
    /// three separate constants, each written for a 28 pt title bar — so in full screen,
    /// where macOS gives the bar a different height, all three were wrong at once and the
    /// brand row sat on the screen's edge.
    ///
    /// The floor is for the case where macOS reports nothing at all: the app still draws
    /// its own name up there and it still needs somewhere to sit.
    @State private var titlebarHeight: CGFloat = 28

    /// The sidebar and the section it selects — the window on every launch but the first.
    private var shell: some View {
        HStack(spacing: 0) {
            sidebarColumn

            // Drawn rather than a `Divider`, which resolves its own colour.
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(width: services.isSidebarCollapsed ? 0 : 1)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Only while the column is away: with it open, the mark and the section
                // are both already in it.
                if services.isSidebarCollapsed {
                    sectionHeader
                }
                permissionBanner
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) { sectionMenuLayer }
        }
        .overlay(alignment: .topLeading) { peekLayer }
        // One reader, at the top, so every inset below comes from the same measurement.
        .background(alignment: .top) {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.safeAreaInsets.top, initial: true) { _, inset in
                        titlebarHeight = max(inset, 28)
                    }
            }
        }
        .animation(.smooth(duration: 0.28), value: services.isSidebarCollapsed)
        .onChange(of: services.isSidebarCollapsed) { _, _ in
            closeWork?.cancel()
            services.isPeeking = false
        }
    }

    /// The column in the window's own flow: its full width, or nothing at all.
    ///
    /// Two frames rather than one. The inner holds the contents at 198 pt so nothing
    /// reflows while the column is moving — a label re-wrapping mid-slide is the tell that
    /// a sidebar is being *resized* rather than put away. The outer is the width that
    /// animates, aligned trailing so the contents slide out to the left instead of being
    /// cut off at the right.
    private var sidebarColumn: some View {
        sidebarBody(topInset: titlebarHeight)
            .ignoresSafeArea(edges: .top)
            .frame(width: Self.sidebarWidth)
        .opacity(services.isSidebarCollapsed ? 0 : 1)
        // Out before the column closes, in after it has opened. Run on the same clock as
        // the width, the labels smear against the moving edge.
        .animation(
            services.isSidebarCollapsed
                ? .easeOut(duration: 0.09)
                : .easeIn(duration: 0.15).delay(0.13),
            value: services.isSidebarCollapsed
        )
        .frame(
            width: services.isSidebarCollapsed ? 0 : Self.sidebarWidth,
            alignment: .trailing
        )
        .clipped()
        // Reaches under the title bar; the contents do not, so the column is one surface
        // with no seam below the traffic lights.
        .glassColumn(.thick)
    }

    // MARK: - The peek

    /// While the column is away: an invisible strip down the window's left edge that
    /// brings it back, and the column itself as a card floating over the content.
    ///
    /// The card rather than the column, because the column would push the content sideways
    /// for as long as the pointer rested there — the reason to put the sidebar away is to
    /// stop the content moving.
    @ViewBuilder
    private var peekLayer: some View {
        if services.isSidebarCollapsed {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: Self.edgeWidth)
                    .frame(maxHeight: .infinity)
                    .overlay {
                        HoverStrip { if $0 { showPeek() } }
                    }

                peekCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The strip that opens it. Wide enough to catch a pointer thrown at the edge of the
    /// screen, narrow enough that it is never in the way of the content beside it.
    static let edgeWidth: CGFloat = 16

    private var peekCard: some View {
        sidebarBody(topInset: 6)
            .frame(width: Self.sidebarWidth)
            .frame(maxHeight: .infinity)
            .glass(.thick, radius: Theme.Radius.pane)
            // Inset from the window rather than flush with it, so it reads as a card over
            // the content and not as the column having come back.
            .padding(EdgeInsets(top: titlebarHeight + 10, leading: 8, bottom: 8, trailing: 0))
            // Leaving the card is the only thing that puts it away. Choosing a section
            // used to as well, which was the bounce: the card slid out from under a
            // pointer that had not moved, its own tracking area read that as an arrival,
            // and it came straight back. Staying open is also the better behaviour — you
            // can look at one section and then another without going back to the edge
            // between them.
            //
            // Entering it only cancels a pending close. The edge opens the card; nothing
            // else does.
            .overlay { HoverStrip { $0 ? keepPeek() : hidePeek() } }
            .offset(x: isPeeking ? 0 : -(Self.sidebarWidth + 26))
            .opacity(isPeeking ? 1 : 0)
            .allowsHitTesting(isPeeking)
            .animation(.smooth(duration: 0.26), value: isPeeking)
    }

    // MARK: - The section header

    /// How far in from the content's left edge the mark and the name sit.
    static let contentGutter: CGFloat = 20
    static let sectionHeaderHeight: CGFloat = 38

    @State private var isHeaderHovered = false

    /// The mark and the section you are in, at the top of the content — and the sections
    /// themselves when the pointer rests on it.
    ///
    /// It used to be in the title bar's accessory beside the toggle, which cost more than
    /// it looked. A title bar accessory is measured once and never again, so it had to be
    /// sized for the longest section name the app could ever show; and in full screen the
    /// title bar auto-hides, taking the name with it exactly when the sidebar is gone too.
    /// In the content it is simply a view: as wide as its text, present in both states,
    /// and the menu below it needs no coordinates read back out of AppKit.
    private var sectionHeader: some View {
        let isOpen = services.sectionMenu.isOpen
        let isLit = isHeaderHovered || isOpen

        return HStack(spacing: 8) {
            MurmrMarkShape()
                .fill(Theme.Palette.gold)
                .frame(width: 15, height: 13.5)
            Text(services.route.label)
                .font(Theme.Text.bodyStrong)
                .foregroundStyle(Theme.Palette.text)
                .fixedSize()
            // Not decoration: a menu that opens on hover with nothing to announce it is a
            // menu nobody knows is there until it surprises them.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .opacity(isLit ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isLit ? Color.white.opacity(0.07) : Color.clear)
        }
        .onHover { hovering in
            // The guard comes before the lit state, not after: the peek card slides
            // across this header on its way in, and the header was taking that as a
            // hover — a chevron appearing under a card nobody pointed at.
            guard !services.isPeeking else { return }
            isHeaderHovered = hovering
            if hovering {
                services.sectionMenu.arm()
            } else {
                services.sectionMenu.scheduleClose()
            }
        }
        .animation(.easeOut(duration: 0.13), value: isLit)
        .onChange(of: services.isPeeking) { _, peeking in
            if peeking { isHeaderHovered = false }
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(services.route.label). Choose a section.")
        .padding(.leading, Self.contentGutter - 8)
        .frame(height: Self.sectionHeaderHeight, alignment: .leading)
    }

    // MARK: - The section menu

    /// The sections, under the header.
    ///
    /// Drawn in the content rather than in the title bar's accessory, which is a view 28 pt
    /// tall and clips anything hanging out of it.
    @ViewBuilder
    private var sectionMenuLayer: some View {
        if services.isSidebarCollapsed {
            SectionMenuView(services: services)
                .scaleEffect(
                    services.sectionMenu.isOpen ? 1 : 0.97, anchor: .topLeading
                )
                .opacity(services.sectionMenu.isOpen ? 1 : 0)
                .allowsHitTesting(services.sectionMenu.isOpen)
                // Under the header, in the same column it sits in. Both numbers are the
                // app's own layout; nothing here is read back out of AppKit.
                //
                // 8pt of daylight, not 2. At 2 the menu's top edge sat against the bottom
                // of the name it drops from, so the two read as one tall slab rather than
                // as a control and the menu it opened. The gap still has to be crossable
                // without the menu closing underneath the pointer — that is what
                // `SectionMenu.closeDelay` is for, and 8 is well inside it.
                .offset(
                    x: Self.contentGutter,
                    y: Self.sectionHeaderHeight + (services.sectionMenu.isOpen ? 8 : 3)
                )
                .animation(.smooth(duration: 0.16), value: services.sectionMenu.isOpen)
        }
    }

    private func showPeek() {
        keepPeek()
        services.isPeeking = true
    }

    /// Cancels a pending close without opening anything.
    ///
    /// What the card itself does when the pointer arrives on it: the errand is still in
    /// progress, so the close that leaving the edge scheduled is off — but a card that is
    /// away stays away.
    private func keepPeek() {
        closeWork?.cancel()
        closeWork = nil
    }

    /// Leaving the card does not put it away at once. The pointer has to cross the gap
    /// between the edge strip and the card, and passes over the traffic lights on the way
    /// to the corner; without the wait the card shuts under the pointer on the way in.
    private func hidePeek() {
        closeWork?.cancel()
        closeWork = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            services.isPeeking = false
        }
    }

    /// A missing permission, said above whichever section is showing. The window used to
    /// route itself to Privacy & data whenever one was off — so ⌘, from the Hotkeys pane
    /// landed somewhere else, and "Settings…" seemed to open the wrong pane. The problem
    /// is now a line you can see from anywhere, and that pane is the one place it is not
    /// repeated, because it lists the same thing with the same button.
    @ViewBuilder
    private var permissionBanner: some View {
        let permissions = services.permissions
        // A grant that is off is said. No conditions.
        //
        // This warning used to be *earned*: shown only once a note existed, on the reading
        // that a dictation-only user has no use for it. Every version of that rule left a
        // hole somewhere, and each patch moved the hole rather than closing it — a note
        // only exists after a meeting has already been half-recorded; a running meeting is
        // too late; a refusal needs the person to have been asked, which needs onboarding,
        // which they can skip.
        //
        // The simple rule has no holes: if the app cannot do something it offers, it says
        // so. Skipping onboarding, refusing, or never being asked all end in the same
        // place, because from the user's side they are the same thing — the Notetaker will
        // not hear anyone else, and nothing on screen admitted it.
        let needsSystemAudio = permissions.systemAudio != .granted
        let hasSomethingToSay = !permissions.allGranted || needsSystemAudio

        if services.route != .settings(.privacyData), hasSomethingToSay {
            VStack(spacing: 8) {
                if permissions.accessibility != .granted {
                    WarningRow(
                        message: "Nothing starts when you press a hotkey \u{2014} Accessibility "
                            + "is off.",
                        action: ("Allow", { permissions.requestAccessibility() })
                    )
                }
                if permissions.microphone != .granted {
                    WarningRow(
                        message: "Nothing can be heard \u{2014} Microphone is off.",
                        action: ("Allow", {
                            if permissions.microphone == .notDetermined {
                                Task { await permissions.requestMicrophone() }
                            } else {
                                permissions.openMicrophoneSettings()
                            }
                        })
                    )
                }
                if needsSystemAudio {
                    WarningRow(
                        message: "Notetaker won\u{2019}t hear other people \u{2014} System "
                            + "audio is off.",
                        action: ("Allow", {
                            // The first probe is what shows Apple's prompt. After a
                            // refusal there is nothing left to ask, so it is the pane.
                            if permissions.systemAudio == .notDetermined {
                                Task { await permissions.requestSystemAudio() }
                            } else {
                                permissions.openSystemAudioSettings()
                            }
                        })
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            // The same 8 that separates the rows from each other. There was none at all
            // before, so the section began flush against the last warning; but matching
            // the top's 20 was worse in its own way — a second, larger gap immediately
            // under a stack already spaced at 8. What follows is one more thing in the
            // column, so it sits at the column's own rhythm.
            .padding(.bottom, 8)
        }
    }

    /// The app's sections on top, Settings pinned to the bottom — where configuration
    /// belongs: last, out of the way, and always in the same place. It used to swap the
    /// whole list for its four panes, which made "where did Home go?" the price of
    /// opening it; now the panes unfold above the gear, and the app's own rows never move.
    ///
    /// Selection is drawn by `SelectableRow`, not by `List`. The system highlight is
    /// `controlAccentColor` — a system-wide setting no app can override — so a selected row
    /// arrived bright blue in the middle of a navy and gold interface.
    ///
    /// `topInset` is the height to leave clear above the brand row: the title bar's own,
    /// read from the safe area, for the column in the window; a few points for the peek
    /// card, which is below the title bar already.
    private func sidebarBody(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)

            SidebarHeader()

            Rectangle()
                .fill(Theme.Palette.hairline.opacity(0.72))
                .frame(height: 1)
                .padding(.horizontal, 14)

            List {
                topLevel
            }
            .listStyle(.sidebar)
            // Hidden, or `List` paints its own opaque sidebar material and the window
            // ends up with a grey column beside a navy one.
            .scrollContentBackground(.hidden)

            settingsBlock
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var topLevel: some View {
        ForEach(Route.top, id: \.self) { route in
            sidebarRow(
                route.label, symbol: route.symbol, isSelected: services.route == route
            ) {
                services.route = route
            }
        }

    }

    /// The gear, and — while Settings is open — its four panes unfolded above it. Not a
    /// `Route` of its own: there is no detail view for "Settings", only for the sections
    /// inside it, so the gear either opens the level or puts you back where you were.
    @ViewBuilder
    private var settingsBlock: some View {
        if services.route.isSettings {
            VStack(spacing: 1) {
                ForEach(SettingsPane.allCases) { pane in
                    sidebarRow(
                        pane.label, symbol: pane.symbol,
                        isSelected: services.route == .settings(pane)
                    ) {
                        services.route = .settings(pane)
                    }
                }
                sidebarRow(
                    "Settings", symbol: "gearshape", isSelected: false,
                    trailing: "chevron.down", isTitle: true
                ) {
                    services.closeSettings()
                }
            }
        } else {
            sidebarRow(
                "Settings", symbol: "gearshape", isSelected: false, trailing: "chevron.up"
            ) {
                services.openSettings()
            }
        }
    }

    private func sidebarRow(
        _ label: String,
        symbol: String,
        isSelected: Bool,
        trailing: String? = nil,
        isTitle: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        SelectableRow(isSelected: isSelected) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    // A fixed width, so the labels line up whatever the glyph's shape.
                    .frame(width: 17)
                    .foregroundStyle(isSelected ? Theme.Palette.gold : Theme.Palette.muted)
                Text(label)
                    .font(isTitle ? Theme.Text.bodyStrong : Theme.Text.body)
                    .foregroundStyle(
                        isSelected || isTitle ? Theme.Palette.text : Theme.Palette.muted
                    )
                Spacer(minLength: 0)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.faint)
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .onTapGesture(perform: action)
    }

    @ViewBuilder
    private var detail: some View {
        switch services.route {
        case .home:
            HomeView(services: services, onOpen: { services.route = $0 })
        case .dictation:
            DictationView(
                dictation: services.dictation,
                history: services.history,
                prompts: services.prompts,
                services: services
            )
        case .notetaker:
            NotetakerView(
                notes: services.notes,
                meetings: services.meetings,
                settings: services.settings,
                prompts: services.prompts,
                permissions: services.permissions,
                services: services
            )
        case .insights:
            InsightsView(history: services.history, settings: services.settings)
        case .settings(let pane):
            SettingsPaneView(pane: pane, services: services)
        }
    }

}

/// The window's name with the mark in front of it, at the top of the sidebar.
///
/// Drawn by the app rather than AppKit — the system title is hidden in `WindowChrome` — so
/// the mark can sit beside the name. Most Mac apps leave their face to the Dock; this one
/// has no Dock icon, so the window is where it has to show it.
///
/// It used to sit *in* the title bar's row, inset 92 pt to clear the traffic lights. Two
/// things were wrong with that. The inset left 106 pt of a 198 pt column for a mark and
/// ten characters, which is a couple of points from truncating. And macOS draws the title
/// bar as a surface above the content view, so the row came out grey on navy — the
/// washed-out header. The row now sits under the title bar, where it has the column's full
/// width; the toggle that does belong up there is `TitleBarControls`, which is AppKit's own.
struct SidebarHeader: View {
    /// Tall enough to be a band of its own rather than a line of text stuck to the top.
    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 9) {
            MurmrMarkShape()
                .fill(Theme.Palette.gold)
                .frame(width: 17, height: 15.3)
            Text("Murmr Flow")
                .font(Theme.Text.bodyStrong)
                .foregroundStyle(Theme.Palette.text)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
