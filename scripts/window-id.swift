// Prints the window number of an app's main window, for `screencapture -l`.
//
// `screencapture -w` can do this by asking you to click, which is fine once and
// tiresome six times. Owner name and bounds come back from the window server without
// Screen Recording permission; only the window *title* needs it, and we don't use the
// title — so this half works even before the capture itself is allowed.
//
//     swift scripts/window-id.swift [owner-name]

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MurmrFlow"

guard
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("cannot read the window list\n".utf8))
    exit(1)
}

/// The app puts several windows on screen — the floating panel, the menu bar item's
/// own window. The main window is the big one, so take the largest by area rather than
/// the first by z-order, which would pick whichever happens to be in front.
var best: (number: Int, area: Double)?

for window in windows {
    guard
        window[kCGWindowOwnerName as String] as? String == owner,
        let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double,
        let height = bounds["Height"] as? Double
    else { continue }

    let area = width * height
    // Below this is the panel or a shadow-only helper window, never the main one.
    guard area > 120_000 else { continue }
    if best == nil || area > best!.area { best = (number, area) }
}

guard let best else {
    FileHandle.standardError.write(Data("no main window for \(owner)\n".utf8))
    exit(1)
}

print(best.number)
