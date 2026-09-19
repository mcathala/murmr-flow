import Testing

@testable import MurmrFlow

/// The waiting either side of the section menu.
///
/// It is the part of a hover menu that decides whether it is pleasant or infuriating, and
/// it is invisible: nothing on screen says whether a menu opened because you rested on it
/// or because you happened to pass over it. So it is asserted rather than eyeballed.
///
/// `.serialized`, and every wait has room to spare. These are the only tests here that
/// measure real time, and the rest of the suite runs in parallel on the same main actor —
/// a tight margin does not fail because the timing is wrong, it fails because a hundred
/// other tests were in the queue first.
@Suite("The section menu's timing", .serialized)
@MainActor
struct SectionMenuTests {

    private static let slack = Duration.milliseconds(400)

    private func waitPastOpen() async {
        try? await Task.sleep(for: SectionMenu.openDelay + Self.slack)
    }

    private func waitPastClose() async {
        try? await Task.sleep(for: SectionMenu.closeDelay + Self.slack)
    }

    @Test("arriving on the name does not open it at once")
    func armingIsNotOpening() {
        let menu = SectionMenu()
        menu.arm()
        #expect(menu.isOpen == false, "the menu opened on contact; the wait is the design")
    }

    @Test("resting on the name opens it")
    func restingOpensIt() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()
        #expect(menu.isOpen)
    }

    /// The case the delay exists for. The name sits between the traffic lights and the
    /// left edge, so a pointer on its way somewhere crosses it — and must leave it shut.
    @Test("crossing the name and leaving opens nothing")
    func crossingOpensNothing() async {
        let menu = SectionMenu()
        menu.arm()
        menu.disarm()
        await waitPastOpen()
        #expect(menu.isOpen == false)
    }

    @Test("leaving does not shut it at once")
    func closingWaitsToo() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()

        menu.scheduleClose()
        // The pointer is still crossing the gap between the name and the menu below it.
        #expect(menu.isOpen, "it shut in the gap, under the pointer on its way in")
    }

    @Test("reaching the menu keeps it open")
    func reachingItKeepsIt() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()

        menu.scheduleClose()
        menu.keepOpen()
        await waitPastClose()
        #expect(menu.isOpen)
    }

    @Test("leaving the menu shuts it")
    func leavingShutsIt() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()

        menu.scheduleClose()
        await waitPastClose()
        #expect(menu.isOpen == false)
    }

    @Test("choosing a section shuts it with no wait")
    func choosingShutsItNow() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()

        menu.close()
        #expect(menu.isOpen == false)
    }

    /// Re-arming while a close is pending is the pointer coming back. It should stay open
    /// rather than shut and reopen under the hand that returned to it.
    @Test("coming back before it shuts leaves it open")
    func comingBackKeepsIt() async {
        let menu = SectionMenu()
        menu.arm()
        await waitPastOpen()

        menu.scheduleClose()
        menu.arm()
        await waitPastClose()
        #expect(menu.isOpen)
    }

    /// What the peek calls when it takes the pointer, and what the toggle calls when the
    /// column comes back. Both go through `close()`, so this is the whole of that rule —
    /// the wiring in `AppServices` is one line each and would cost a test the app's
    /// singleton and a write to the user's real defaults.
    @Test("closing an armed menu stops it opening later")
    func closingWhileArmedStopsIt() async {
        let menu = SectionMenu()
        menu.arm()
        menu.close()
        await waitPastOpen()
        #expect(menu.isOpen == false, "it opened after something else took the pointer")
    }
}
