import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

enum VirtualDisplayError: LocalizedError {
    case busy
    case createFailed
    case applyFailed
    case notOnline(String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "正在切换虚拟显示器"
        case .createFailed:
            return "无法创建虚拟显示器"
        case .applyFailed:
            return "虚拟显示器初始化失败"
        case .notOnline(let message):
            return "虚拟显示器未能上线：\(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .busy:
            return "请等待当前切换完成后再试。"
        case .createFailed, .applyFailed:
            return "请完全退出 App 后重试；如果仍然失败，请重启 Mac 再试。虚拟显示器依赖 macOS 私有接口，系统更新后可能失效。"
        case .notOnline:
            return "请稍后重试。若系统显示设置无响应，请先重启 Mac，不要连续反复切换。"
        }
    }
}

/// Owns exactly one virtual display at a time.
///
/// macOS virtual displays are created through the private CGVirtualDisplay API.
/// Each display is created with a single mode; switching presets builds a new
/// display, waits for it to become stable, then releases the old one. Releasing
/// a display too soon after creation can wedge WindowServer's display
/// configuration, so a small minimum lifetime is enforced.
final class VirtualDisplayController {
    static let shared = VirtualDisplayController()

    private(set) var activePreset: Preset?
    private(set) var activeScaleMode: ScaleMode?
    private(set) var displayID: CGDirectDisplayID?
    private(set) var scaleMode: ScaleMode
    private(set) var isBusy = false {
        didSet { stateDidChange?() }
    }

    /// Called on the main thread whenever the UI-visible state changes.
    var stateDidChange: (() -> Void)?

    private var display: CGVirtualDisplay?
    private var bornAt: Date?
    private var pending: [(display: CGVirtualDisplay, bornAt: Date)] = []
    private var reconfigurationWorkItem: DispatchWorkItem?
    private var staleConfirmationWorkItem: DispatchWorkItem?
    private let minimumLifetime: TimeInterval = 2.5

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "scaleMode"),
           let saved = ScaleMode(rawValue: raw) {
            scaleMode = saved
        } else {
            scaleMode = .pointPerfect
        }
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    // MARK: - State

    var statusTitle: String {
        if isBusy { return "正在切换虚拟显示器…" }
        if let preset = activePreset {
            return "虚拟屏：\(preset.name) · \(preset.pixelLabel)"
        }
        return "虚拟屏：未启用"
    }

    var statusDetail: String {
        if isBusy { return "请稍候，切换期间画面可能会短暂闪烁" }
        if let preset = activePreset {
            return preset.detailLabel(for: activeScaleMode ?? scaleMode)
        }
        return "默认 \(Preset.default.pixelLabel) · 当前渲染：\(scaleMode.shortTitle)"
    }

    var canClose: Bool {
        activePreset != nil && !isBusy
    }

    /// Re-check that the display we think we own is still present. Called when
    /// the menu opens and after macOS reconfigures displays.
    func refreshState() {
        guard !isBusy, let id = displayID, activePreset != nil else { return }
        guard !isDisplayOnline(id) else { return }

        // Display reconfiguration can transiently omit a display. Confirm the
        // loss before dropping the active state.
        staleConfirmationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isBusy,
                  self.displayID == id,
                  let preset = self.activePreset,
                  !self.isDisplayOnline(id) else {
                return
            }

            let stale = self.display
            let staleBirth = self.bornAt
            self.display = nil
            self.displayID = nil
            self.activePreset = nil
            self.activeScaleMode = nil
            self.bornAt = nil
            if let stale, let staleBirth {
                self.retire(stale, bornAt: staleBirth)
            }
            NSLog("ResSwitch: virtual display #\(id) for \(preset.name) disappeared")
            self.stateDidChange?()
        }
        staleConfirmationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    // MARK: - Public actions

    func apply(
        _ preset: Preset,
        force: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isBusy else {
            completion(.failure(VirtualDisplayError.busy))
            return
        }

        if !force,
           activePreset == preset,
           activeScaleMode == scaleMode,
           let id = displayID,
           display != nil,
           isDisplayOnline(id) {
            completion(.success(()))
            return
        }

        let mode = scaleMode
        isBusy = true

        let oldDisplay = display
        let oldBirth = bornAt
        let created: (display: CGVirtualDisplay, id: CGDirectDisplayID, bornAt: Date)
        do {
            created = try makeDisplay(preset, mode: mode)
        } catch {
            isBusy = false
            completion(.failure(error))
            return
        }

        waitForOnline(
            created.id,
            preset: preset,
            deadline: Date().addingTimeInterval(5.0)
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.retire(created.display, bornAt: created.bornAt)
                self.isBusy = false
                completion(.failure(error))

            case .success:
                self.finishSwitch(
                    newDisplay: created.display,
                    newID: created.id,
                    newBirth: created.bornAt,
                    preset: preset,
                    mode: mode,
                    oldDisplay: oldDisplay,
                    oldBirth: oldBirth,
                    completion: completion
                )
            }
        }
    }

    func setScaleMode(
        _ mode: ScaleMode,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isBusy else {
            completion(.failure(VirtualDisplayError.busy))
            return
        }
        guard mode != scaleMode else {
            completion(.success(()))
            return
        }

        scaleMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "scaleMode")

        if let preset = activePreset, display != nil {
            apply(preset, force: true, completion: completion)
        } else {
            stateDidChange?()
            completion(.success(()))
        }
    }

    func disable(completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isBusy else {
            completion(.failure(VirtualDisplayError.busy))
            return
        }
        guard let oldDisplay = display else {
            activePreset = nil
            activeScaleMode = nil
            displayID = nil
            completion(.success(()))
            return
        }

        isBusy = true
        let oldBirth = bornAt ?? Date()
        let wait = remainingLifetime(for: oldBirth)

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.display = nil
            self.displayID = nil
            self.activePreset = nil
            self.activeScaleMode = nil
            self.bornAt = nil
            self.retire(oldDisplay, bornAt: oldBirth)
            self.isBusy = false
            completion(.success(()))
        }
    }

    /// Called from applicationShouldTerminate. Gives a freshly-created display
    /// enough time to settle before the process releases it.
    func prepareForTermination(completion: @escaping () -> Void) {
        if isBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.prepareForTermination(completion: completion)
            }
            return
        }

        guard let birth = bornAt, display != nil else {
            completion()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + remainingLifetime(for: birth)) { [weak self] in
            self?.display = nil
            self?.displayID = nil
            self?.activePreset = nil
            self?.activeScaleMode = nil
            self?.bornAt = nil
            self?.pending.removeAll()
            completion()
        }
    }

    // MARK: - Creation

    private func makeDisplay(
        _ preset: Preset,
        mode: ScaleMode
    ) throws -> (CGVirtualDisplay, CGDirectDisplayID, Date) {
        let hiDPI = preset.usesHiDPI(for: mode)
        let logicalWidth = preset.logicalWidth(for: mode)
        let logicalHeight = preset.logicalHeight(for: mode)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = preset.displayName
        descriptor.maxPixelsWide = UInt32(preset.width)
        descriptor.maxPixelsHigh = UInt32(preset.height)
        descriptor.sizeInMillimeters = preset.sizeInMillimeters(for: mode)
        descriptor.vendorID = 0x5253 // "RS"
        descriptor.productID = 0x0001
        // A random serial avoids a name collision with a previous instance that
        // has not been torn down yet (initWithDescriptor: can return nil then).
        descriptor.serialNum = UInt32.random(in: 1...0xFFFF_FFFE)
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
        descriptor.redPrimary = CGPoint(x: 0.6797, y: 0.3203)
        descriptor.greenPrimary = CGPoint(x: 0.2559, y: 0.6983)
        descriptor.bluePrimary = CGPoint(x: 0.1494, y: 0.0557)

        let birth = Date()
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.createFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt(logicalWidth),
                height: UInt(logicalHeight),
                refreshRate: 60
            )
        ]

        guard display.apply(settings) else {
            // The object may already be registered even though apply failed.
            // Keep it around for the minimum lifetime so teardown is safe.
            pending.append((display, birth))
            flushPending()
            throw VirtualDisplayError.applyFailed
        }

        NSLog(
            "ResSwitch: created virtual display #\(display.displayID) " +
            "\(preset.pixelLabel) logical=\(logicalWidth)×\(logicalHeight) " +
            "hiDPI=\(hiDPI) mode=\(mode.rawValue)"
        )
        return (display, display.displayID, birth)
    }

    private func finishSwitch(
        newDisplay: CGVirtualDisplay,
        newID: CGDirectDisplayID,
        newBirth: Date,
        preset: Preset,
        mode: ScaleMode,
        oldDisplay: CGVirtualDisplay?,
        oldBirth: Date?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let wait = remainingLifetime(for: newBirth)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }

            guard self.isDisplayOnline(newID) else {
                self.retire(newDisplay, bornAt: newBirth)
                self.isBusy = false
                completion(
                    .failure(
                        VirtualDisplayError.notOnline(
                            "新虚拟屏 #\(newID) 在稳定检查时掉线（\(self.currentModeLabel(newID))）"
                        )
                    )
                )
                return
            }

            self.display = newDisplay
            self.displayID = newID
            self.activePreset = preset
            self.activeScaleMode = mode
            self.bornAt = newBirth
            self.isBusy = false

            if let oldDisplay {
                self.retire(oldDisplay, bornAt: oldBirth ?? Date.distantPast)
            }
            completion(.success(()))
        }
    }

    private func waitForOnline(
        _ id: CGDirectDisplayID,
        preset: Preset,
        deadline: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if isDisplayOnline(id) {
            completion(.success(()))
            return
        }

        if Date() >= deadline {
            completion(
                .failure(
                    VirtualDisplayError.notOnline(
                        "5 秒内没有等到 \(preset.pixelLabel)；" +
                        "当前 \(currentModeLabel(id))；online=\(CGDisplayIsOnline(id))"
                    )
                )
            )
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForOnline(id, preset: preset, deadline: deadline, completion: completion)
        }
    }

    /// A virtual display can be online and usable while
    /// CGDisplayCopyDisplayMode still returns nil for it (observed on macOS
    /// 27 with a display created by the same non-GUI test process). The mode
    /// was already selected by applySettings, so being online is the reliable
    /// readiness signal here.
    private func isDisplayOnline(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) != 0 || DisplayInfo.onlineIDs().contains(id)
    }

    private func currentModeLabel(_ id: CGDirectDisplayID) -> String {
        guard let mode = DisplayInfo.currentMode(id) else { return "未知" }
        return "\(mode.width)×\(mode.height)pt / \(mode.pixelWidth)×\(mode.pixelHeight)px"
    }

    // MARK: - Lifetime helpers

    private func remainingLifetime(for birth: Date) -> TimeInterval {
        max(0, minimumLifetime - Date().timeIntervalSince(birth))
    }

    private func retire(_ display: CGVirtualDisplay, bornAt: Date) {
        pending.append((display, bornAt))
        flushPending()
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let now = Date()
        pending.removeAll { now.timeIntervalSince($0.bornAt) >= minimumLifetime }

        guard let next = pending.min(by: { $0.bornAt < $1.bornAt }) else { return }
        let wait = max(0.1, remainingLifetime(for: next.bornAt) + 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.flushPending()
        }
    }

    // MARK: - Reconfiguration

    fileprivate func scheduleReconfigurationCheck() {
        reconfigurationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshState()
        }
        reconfigurationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }
}

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    DispatchQueue.main.async {
        VirtualDisplayController.shared.scheduleReconfigurationCheck()
    }
}
