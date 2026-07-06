import Foundation
import AppKit
import CoreGraphics

/// A running Toontown window that can be assigned to a control slot.
struct ToonWindow: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    let title: String
    let appName: String
    var frame: CGRect   // Quartz coordinates (origin top-left of main display)

    var displayName: String {
        let base = title.isEmpty ? appName : title
        return "\(base) (pid \(pid))"
    }

    static func == (lhs: ToonWindow, rhs: ToonWindow) -> Bool {
        lhs.pid == rhs.pid && lhs.windowID == rhs.windowID
    }
}

/// Discovers Toontown Rewritten windows and tracks their frames.
final class WindowTracker {

    /// Substrings used to recognize a Toontown game window by owner or title.
    private let matchTerms = ["toontown"]
    /// Windows owned by the launcher are excluded (game window is what we control).
    private let excludeTerms = ["launcher"]

    /// All on-screen Toontown windows, one entry per window.
    func discover() -> [ToonWindow] {
        let results = windowList().compactMap { parseToonWindow($0) }
        // Stable order: by pid, then window ID.
        return results.sorted {
            $0.pid == $1.pid ? $0.windowID < $1.windowID : $0.pid < $1.pid
        }
    }

    /// The Toontown window at a screen point, or nil if the topmost normal
    /// window there isn't a Toontown window. Used for click-to-pick.
    func toonWindow(atQuartzPoint point: CGPoint) -> ToonWindow? {
        let myPid = ProcessInfo.processInfo.processIdentifier

        for entry in windowList() {   // CGWindowList returns front-to-back order
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPid,   // ignore our own windows
                  let frame = frame(of: entry),
                  frame.contains(point)
            else { continue }

            // First normal window under the cursor decides the outcome.
            return parseToonWindow(entry)
        }
        return nil
    }

    /// Fresh frames for specific windows. Returns nil for windows that are gone.
    func currentFrames(for windowIDs: [CGWindowID]) -> [CGWindowID: CGRect] {
        guard !windowIDs.isEmpty else { return [:] }

        let idArray = windowIDs.map { NSNumber(value: $0) } as CFArray
        guard let info = CGWindowListCreateDescriptionFromArray(idArray) as? [[String: Any]]
        else { return [:] }

        var frames: [CGWindowID: CGRect] = [:]
        for entry in info {
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let rect = frame(of: entry)
            else { continue }
            frames[windowID] = rect
        }
        return frames
    }

    /// Whether the process behind a window is still running.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    /// Cocoa screen point (bottom-left origin) → Quartz point (top-left origin).
    static func quartzPoint(fromCocoa point: NSPoint) -> CGPoint {
        guard let primary = NSScreen.screens.first else {
            return CGPoint(x: point.x, y: point.y)
        }
        return CGPoint(x: point.x, y: primary.frame.height - point.y)
    }

    // MARK: - Internals

    private func windowList() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
    }

    private func frame(of entry: [String: Any]) -> CGRect? {
        guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return nil }
        return rect
    }

    /// Parses a CGWindowList entry into a ToonWindow if it looks like a
    /// Toontown game window; nil otherwise.
    private func parseToonWindow(_ entry: [String: Any]) -> ToonWindow? {
        guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
              let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return nil }

        let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
        let title = (entry[kCGWindowName as String] as? String) ?? ""
        let haystack = (ownerName + " " + title).lowercased()

        guard matchTerms.contains(where: { haystack.contains($0) }) else { return nil }
        guard !excludeTerms.contains(where: { haystack.contains($0) }) else { return nil }

        guard let frame = frame(of: entry),
              frame.width >= 200, frame.height >= 150   // skip splash screens etc.
        else { return nil }

        return ToonWindow(pid: pid, windowID: windowID, title: title,
                          appName: ownerName, frame: frame)
    }
}
