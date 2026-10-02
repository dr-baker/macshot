import CoreGraphics
import Foundation

enum ScreenCaptureWindowExclusions {
    static func combining(_ groups: [CGWindowID]...) -> [CGWindowID] {
        var seen = Set<CGWindowID>()
        return groups.flatMap { $0 }.filter { $0 != kCGNullWindowID && seen.insert($0).inserted }
    }

    /// Keep WindowServer's front-to-back order, including desktop windows.
    /// Invalid window metadata must fail the capture rather than omit an exclusion.
    static func includedWindowNumbers(in windows: [[String: Any]], excluding excludedNumbers: [CGWindowID]) -> [CGWindowID]? {
        let excluded = Set(excludedNumbers)
        var included: [CGWindowID] = []
        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? NSNumber,
                  let id = CGWindowID(exactly: number.int64Value), id != kCGNullWindowID else { return nil }
            if !excluded.contains(id) { included.append(id) }
        }
        return included
    }

    /// The CGWindow screenshot API expects integer IDs stored as raw pointers.
    /// A CFArray of NSNumber objects passes object addresses in place of window IDs.
    static func windowArray(for numbers: [CGWindowID]) -> CFArray? {
        guard !numbers.isEmpty else { return nil }
        var identifiers = numbers.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(nil, &identifiers, identifiers.count, nil)
    }
}
