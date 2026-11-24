import CoreGraphics
import Foundation

enum DisplayInfo {
    static func onlineIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func currentMode(_ id: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(id)
    }

    static func describe(_ id: CGDirectDisplayID) -> String {
        let bounds = CGDisplayBounds(id)
        let mode = currentMode(id)
        let pixels = mode.map { "\($0.pixelWidth)×\($0.pixelHeight)px" } ?? "?"
        let points = mode.map { "\($0.width)×\($0.height)pt" } ?? "?"
        let hz = mode.map { String(format: "%.0fHz", $0.refreshRate) } ?? "?"
        let main = CGDisplayIsMain(id) != 0 ? " [main]" : ""
        let vendor = String(format: "0x%08x", CGDisplayVendorNumber(id))
        return "#\(id)  \(points)  \(pixels)  \(hz)  origin(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)))  vendor=\(vendor)\(main)"
    }

    static func dump() -> String {
        var lines: [String] = []
        for id in onlineIDs() {
            lines.append(describe(id))
            guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] else {
                lines.append("    modes: read failed")
                continue
            }
            let sorted = modes.sorted {
                ($0.pixelWidth, $0.pixelHeight, $0.refreshRate) <
                ($1.pixelWidth, $1.pixelHeight, $1.refreshRate)
            }
            for mode in sorted {
                lines.append(
                    "    \(mode.width)×\(mode.height)pt  " +
                    "\(mode.pixelWidth)×\(mode.pixelHeight)px  " +
                    String(format: "@%.0fHz", mode.refreshRate)
                )
            }
        }
        if lines.isEmpty { lines.append("(no online displays)") }
        return lines.joined(separator: "\n")
    }
}
