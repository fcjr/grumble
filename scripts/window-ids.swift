// Lists on-screen window ids for an app, so `screencapture -l <id>` can grab a
// window without the interactive click that `screencapture -w` needs. Used to
// capture real app windows for the App Store screenshots.
//
// Usage: swift scripts/window-ids.swift [owner-substring]

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Grumble"
let windows =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    guard let name = window[kCGWindowOwnerName as String] as? String,
        owner.isEmpty || name.localizedCaseInsensitiveContains(owner)
    else { continue }
    let id = window[kCGWindowNumber as String] as? Int ?? -1
    let title = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = Int(bounds["Width"] as? Double ?? 0)
    let height = Int(bounds["Height"] as? Double ?? 0)
    print("\(id)\t\(name)\t\(width)x\(height)\t\"\(title)\"")
}
