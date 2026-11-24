import CoreGraphics
import Foundation

/// How the physical pixels are mapped onto a logical desktop.
enum ScaleMode: String, CaseIterable {
    /// One desktop point per physical pixel. The remote client receives an
    /// exact 1:1 image; UI is as small as it would be on the equivalent
    /// physical monitor running at 1x.
    case pointPerfect

    /// 2x rendering for the presets that benefit from it (4K, iPad).
    /// The framebuffer is still the full client pixel size (1:1), but the
    /// logical desktop is half the pixel size, so UI is native-sized.
    case hiDPI

    var title: String {
        switch self {
        case .pointPerfect: return "点对点 1×（1:1，UI 更小）"
        case .hiDPI: return "原生 2×（4K / iPad / MBP 16）"
        }
    }

    var shortTitle: String {
        switch self {
        case .pointPerfect: return "点对点 1×"
        case .hiDPI: return "原生 2×"
        }
    }
}

/// A client-resolution preset.
///
/// `width`/`height` are always the *physical pixels* the remote client expects.
/// In point-perfect mode the logical desktop is the same size. In HiDPI mode
/// supported presets use a half-sized logical desktop with a 2x backing store.
struct Preset: Identifiable, Hashable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    /// Whether this preset uses 2x when the user selects "原生 2×".
    let supportsHiDPI: Bool
    /// Real-world density for the HiDPI mode, used so macOS picks the intended
    /// default mode. Point-perfect mode always declares a large 1x panel.
    let hiDPIPixelsPerInch: Double
    /// Additional "looks like" sizes offered by the HiDPI virtual display, so
    /// the user can adjust the UI scale from System Settings like on a native
    /// panel. Each size is a logical point size backed at 2x; all of them must
    /// fit inside `width` × `height` physical pixels.
    var hiDPIExtraSizes: [CGSize] = []

    func usesHiDPI(for mode: ScaleMode) -> Bool {
        mode == .hiDPI && supportsHiDPI
    }

    func logicalWidth(for mode: ScaleMode) -> Int {
        usesHiDPI(for: mode) ? width / 2 : width
    }

    func logicalHeight(for mode: ScaleMode) -> Int {
        usesHiDPI(for: mode) ? height / 2 : height
    }

    /// Sizes passed to the virtual display. The first entry is the preset's own
    /// logical size and the one macOS selects by default. HiDPI presets may add
    /// smaller "looks like" sizes for UI-scale adjustment.
    func modeSizes(for mode: ScaleMode) -> [CGSize] {
        let base = CGSize(width: logicalWidth(for: mode), height: logicalHeight(for: mode))
        guard usesHiDPI(for: mode) else { return [base] }
        return [base] + hiDPIExtraSizes
    }

    var pixelLabel: String { "\(width)×\(height)" }

    var menuTitle: String { "\(name)  ·  \(pixelLabel)" }

    func detailLabel(for mode: ScaleMode) -> String {
        if usesHiDPI(for: mode) {
            return "\(pixelLabel) · 逻辑 \(logicalWidth(for: mode))×\(logicalHeight(for: mode)) · 原生 2× · 可调大小"
        }
        if mode == .pointPerfect {
            return "\(pixelLabel) · 点对点 1×"
        }
        return "\(pixelLabel) · 标准 1×"
    }

    var displayName: String { "ResSwitch · \(name)" }

    /// A virtual display must not be reported as a comically small monitor.
    /// Point-perfect mode declares a large panel (110 PPI) so macOS does not
    /// mistake a high-resolution mode for a Retina display and silently pick
    /// a half-sized "looks like" mode. HiDPI mode declares the preset's real
    /// density (27" 4K, 12.9" iPad) so macOS picks the intended 2x mode.
    /// A minimum area of 200 cm² avoids a macOS 26 online-detection quirk.
    func sizeInMillimeters(for mode: ScaleMode) -> CGSize {
        let ppi = usesHiDPI(for: mode) ? hiDPIPixelsPerInch : 110.0
        var w = Double(width) / ppi * 25.4
        var h = Double(height) / ppi * 25.4

        // macOS 26/27 always picks 1920×1080 as the "default" mode of a
        // 3840-pixel-wide 1x virtual display, whatever physical size we
        // declare. If the panel is so wide that this auto-selected mode falls
        // below macOS's 72 DPI activation floor, WindowServer never brings the
        // display online at all (4K at 110 PPI is a 35" panel: 1920 px on it
        // is 55 DPI, and the display stays inactive forever). Cap the declared
        // width of 4K-class 1x panels; the requested mode is then applied
        // explicitly after the display is online.
        if !usesHiDPI(for: mode), width >= 3840 {
            let maxOneXPanelWidthMM = 600.0
            if w > maxOneXPanelWidthMM {
                h *= maxOneXPanelWidthMM / w
                w = maxOneXPanelWidthMM
            }
        }

        let areaCM2 = (w / 10.0) * (h / 10.0)
        if areaCM2 < 200.0, areaCM2 > 0 {
            let factor = sqrt(200.0 / areaCM2)
            w *= factor
            h *= factor
        }
        return CGSize(width: w, height: h)
    }

    static let all: [Preset] = [
        // 1920×1080, 1x — default
        Preset(id: "1080p", name: "1080p", width: 1920, height: 1080, supportsHiDPI: false, hiDPIPixelsPerInch: 110),
        // 27" 2560×1440, 1x
        Preset(id: "2k", name: "2K", width: 2560, height: 1440, supportsHiDPI: false, hiDPIPixelsPerInch: 110),
        // 27" 3840×2160; 2x mode looks like 1920×1080
        Preset(
            id: "4k",
            name: "4K",
            width: 3840,
            height: 2160,
            supportsHiDPI: true,
            hiDPIPixelsPerInch: 163,
            hiDPIExtraSizes: [
                CGSize(width: 1680, height: 945),
                CGSize(width: 1600, height: 900),
                CGSize(width: 1440, height: 810),
                CGSize(width: 1280, height: 720)
            ]
        ),
        // iPad Pro 12.9" 2018; 2x mode looks like 1366×1024
        Preset(id: "ipad", name: "iPad Pro 2018", width: 2732, height: 2048, supportsHiDPI: true, hiDPIPixelsPerInch: 264),
        // MacBook Pro 16" 2021 (M1 Pro/Max); 2x mode looks like 1728×1117
        Preset(id: "mbp16", name: "MacBook Pro 16″", width: 3456, height: 2234, supportsHiDPI: true, hiDPIPixelsPerInch: 254),
        // 34" 3440×1440, 1x
        Preset(id: "3440", name: "超宽屏", width: 3440, height: 1440, supportsHiDPI: false, hiDPIPixelsPerInch: 110)
    ]

    static let `default` = all[0]

    static func preset(id: String) -> Preset? {
        all.first { $0.id == id }
    }
}
