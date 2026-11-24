import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

enum VirtualDisplayError: LocalizedError {
    case busy
    case createFailed
    case applyFailed
    case notOnline
    case modeNotApplied
    case lastDisplay
    case terminating

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Switch in progress"
        case .createFailed:
            return "Couldn't create the virtual display"
        case .applyFailed:
            return "Couldn't configure the virtual display"
        case .notOnline:
            return "Virtual display didn't come online"
        case .modeNotApplied:
            return "Resolution didn't apply"
        case .lastDisplay:
            return "This is the only display"
        case .terminating:
            return "ResSwitch is quitting"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .busy:
            return "Wait for it to finish."
        case .createFailed, .applyFailed:
            return "Quit and reopen ResSwitch. Restart the Mac if it still fails."
        case .notOnline:
            return "Try again. Restart the Mac if it keeps failing."
        case .modeNotApplied:
            return "Set any screen-sharing or virtual display app to the same resolution, then try again."
        case .lastDisplay:
            return "Connect a display first."
        case .terminating:
            return "Wait for it to finish."
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

    /// Set while `applicationShouldTerminate` is waiting for displays to settle.
    /// New switching requests are rejected so the quit path cannot be raced by
    /// a preset click, and the menu can show a distinct "quitting" state.
    private(set) var isTerminating = false {
        didSet { stateDidChange?() }
    }

    /// Called on the main thread whenever the UI-visible state changes.
    var stateDidChange: (() -> Void)?

    private var display: CGVirtualDisplay?
    /// The display being created by an in-flight switch, before it becomes the
    /// active one. Needed so a quit during the 2.5 s settle window can still
    /// detect that the new display is the only screen.
    private var provisioningDisplayID: CGDirectDisplayID?
    private var bornAt: Date?
    private var pending: [(display: CGVirtualDisplay, bornAt: Date)] = []
    private var reconfigurationWorkItem: DispatchWorkItem?
    private var staleConfirmationWorkItem: DispatchWorkItem?
    private var terminationCompletion: (() -> Void)?
    private let minimumLifetime: TimeInterval = 2.5

    private init() {
        if let raw = UserDefaults.standard.string(forKey: "scaleMode"),
           let saved = ScaleMode(rawValue: raw) {
            scaleMode = saved
        } else {
            // Native-like default: 2x "looks like" sizes for the presets that
            // support it (4K looks like 1920×1080 while still outputting
            // 3840×2160 pixels). 1080p/2K/Ultrawide declare supportsHiDPI=false
            // and are unaffected.
            scaleMode = .hiDPI
        }
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, nil)
    }

    // MARK: - State

    var statusTitle: String {
        if isTerminating { return "Quitting…" }
        if isBusy { return "Switching…" }
        if let preset = activePreset {
            return "On · \(preset.pixelLabel)"
        }
        return "No virtual display"
    }

    /// True when every display that is currently online belongs to ResSwitch.
    ///
    /// Releasing our displays would then leave the Mac with no screen at all,
    /// and a headless machine has no GUI left to recreate one. Close/quit
    /// therefore require an explicit confirmation, and the stale-display check
    /// must never retire the last display on its own. The active display, an
    /// in-flight replacement, and retired displays still inside their minimum
    /// lifetime are all considered, because any of them may be online. Returns
    /// `true` when the online list cannot be read (empty), which is the
    /// conservative choice: we would rather ask for confirmation than silently
    /// remove the only screen.
    var isSoleOnlineDisplay: Bool {
        var owned = [displayID, provisioningDisplayID].compactMap { $0 }
        // Displays retired during a switch stay online until their minimum
        // lifetime expires; they are still ours and quitting would drop them.
        owned += pending.map { $0.display.displayID }
        guard !owned.isEmpty else { return false }
        return DisplayInfo.onlineIDs().allSatisfy { owned.contains($0) }
    }

    /// True when at least one display is online, so a confirmation dialog has
    /// somewhere to appear. When false there is no screen left to protect and
    /// no way to show an alert; a modal there would block termination forever.
    var hasOnlineDisplay: Bool {
        if let id = displayID, CGDisplayIsOnline(id) != 0 { return true }
        if let id = provisioningDisplayID, CGDisplayIsOnline(id) != 0 { return true }
        if pending.contains(where: { CGDisplayIsOnline($0.display.displayID) != 0 }) { return true }
        return !DisplayInfo.onlineIDs().isEmpty
    }

    var canClose: Bool {
        activePreset != nil && !isBusy && !isTerminating
    }

    /// Re-check that the display we think we own is still present. Called when
    /// the menu opens and after macOS reconfigures displays.
    func refreshState() {
        guard !isTerminating else { return }
        guard !isBusy, let id = displayID, activePreset != nil else { return }
        guard !isDisplayOnline(id) else { return }

        // Display reconfiguration can transiently omit a display. Confirm the
        // loss before dropping the active state.
        staleConfirmationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.isTerminating,
                  !self.isBusy,
                  self.displayID == id,
                  let preset = self.activePreset,
                  !self.isDisplayOnline(id) else {
                return
            }

            // Never destroy the only remaining screen. If the display is
            // really gone there is nothing left to show anyway; keeping the
            // object alive is recoverable, releasing it is not.
            guard !self.isSoleOnlineDisplay else {
                NSLog("ResSwitch: display #\(id) is offline but is the only online display; keeping it")
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

        guard !isTerminating else {
            completion(.failure(VirtualDisplayError.terminating))
            return
        }
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
            provisioningDisplayID = nil
            isBusy = false
            completion(.failure(error))
            return
        }
        provisioningDisplayID = created.id

        settle(
            created.id,
            preset: preset,
            mode: mode,
            bornAt: created.bornAt,
            deadline: DispatchTime.now() + 12.0
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.provisioningDisplayID = nil
                self.retire(created.display, bornAt: created.bornAt)
                self.isBusy = false
                completion(.failure(error))

            case .success:
                self.provisioningDisplayID = nil
                self.display = created.display
                self.displayID = created.id
                self.activePreset = preset
                self.activeScaleMode = mode
                self.bornAt = created.bornAt
                self.isBusy = false

                if let oldDisplay {
                    self.retire(oldDisplay, bornAt: oldBirth ?? Date.distantPast)
                }
                completion(.success(()))
            }
        }
    }

    func setScaleMode(
        _ mode: ScaleMode,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isTerminating else {
            completion(.failure(VirtualDisplayError.terminating))
            return
        }
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

    func disable(
        allowingSoleDisplay: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard !isTerminating else {
            completion(.failure(VirtualDisplayError.terminating))
            return
        }
        guard !isBusy else {
            completion(.failure(VirtualDisplayError.busy))
            return
        }
        guard let oldDisplay = display else {
            provisioningDisplayID = nil
            activePreset = nil
            activeScaleMode = nil
            displayID = nil
            completion(.success(()))
            return
        }
        // Callers that destroy the last screen must opt in explicitly; the UI
        // asks the user first. A race between the check and this call still
        // fails closed instead of silently removing the only display. When no
        // display is online at all there is nothing left to protect, so the
        // release is allowed even without the explicit opt-in.
        guard allowingSoleDisplay || !isSoleOnlineDisplay || !hasOnlineDisplay else {
            completion(.failure(VirtualDisplayError.lastDisplay))
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

    /// Called from applicationShouldTerminate. Gives the active display and any
    /// retired-but-not-yet-released display enough time to settle, so the
    /// process does not release a fresh display too early. The wait is bounded:
    /// a wedged WindowServer must never prevent the app from quitting.
    func prepareForTermination(
        timeout: TimeInterval = 8.0,
        completion: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard terminationCompletion == nil else { return }
        terminationCompletion = completion
        isTerminating = true
        staleConfirmationWorkItem?.cancel()
        reconfigurationWorkItem?.cancel()

        let deadline = DispatchTime.now() + max(0.5, timeout)
        waitForIdleBeforeTermination(deadline: deadline)
    }

    private func waitForIdleBeforeTermination(deadline: DispatchTime) {
        guard terminationCompletion != nil else { return }

        if isBusy {
            guard DispatchTime.now() < deadline else {
                NSLog("ResSwitch: termination deadline reached while busy; forcing cleanup")
                finishTermination()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForIdleBeforeTermination(deadline: deadline)
            }
            return
        }

        // Also wait for displays that were retired but are still inside their
        // minimum lifetime. Dropping those immediately on quit is exactly the
        // early-release hazard the minimum lifetime exists to prevent.
        let births = [bornAt].compactMap { $0 } + pending.map { $0.bornAt }
        let wait = min(3.0, births.map { remainingLifetime(for: $0) }.max() ?? 0)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.finishTermination()
            }
        } else {
            finishTermination()
        }
    }

    private func finishTermination() {
        guard terminationCompletion != nil else { return }

        let pendingCount = pending.count
        display = nil
        provisioningDisplayID = nil
        displayID = nil
        activePreset = nil
        activeScaleMode = nil
        bornAt = nil
        pending.removeAll()
        isBusy = false

        NSLog("ResSwitch: termination cleanup released \(pendingCount) pending display(s)")
        let completion = terminationCompletion
        terminationCompletion = nil
        completion?()
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
        settings.modes = preset.modeSizes(for: mode).map {
            CGVirtualDisplayMode(
                width: UInt($0.width),
                height: UInt($0.height),
                refreshRate: 60
            )
        }

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
            "modes=\(settings.modes.count) hiDPI=\(hiDPI) mode=\(mode.rawValue)"
        )
        return (display, display.displayID, birth)
    }

    /// Wait until the new display is online and has stayed online for a
    /// short settle window, then make sure it is really running the requested
    /// mode, and only then let the caller commit the switch (which retires
    /// the previous display).
    ///
    /// Two macOS 26/27 quirks are handled here:
    /// - The system applies a "default configuration" right after creation and
    ///   switches a 4K display to 1920×1080, no matter which mode was applied.
    /// - A process that has already queried displays before creating a virtual
    ///   display cannot read that display's mode list afterwards. So the mode
    ///   is applied by a short-lived copy of this executable, which starts with
    ///   a clean display connection.
    private func settle(
        _ id: CGDirectDisplayID,
        preset: Preset,
        mode: ScaleMode,
        bornAt: Date,
        deadline: DispatchTime,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let readyAt = bornAt.addingTimeInterval(minimumLifetime)
        var onlineSince: Date?
        var modeAttempts = 0

        func fail(_ error: VirtualDisplayError) {
            NSLog("ResSwitch: display #\(id) failed to settle: \(error.localizedDescription)")
            completion(.failure(error))
        }

        func enforceMode() {
            modeAttempts += 1
            applyModeExternally(id, preset: preset, mode: mode) { applied in
                if applied {
                    completion(.success(()))
                    return
                }
                if modeAttempts < 3, DispatchTime.now() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: enforceMode)
                } else {
                    NSLog("ResSwitch: display #\(id) mode not applied (current \(self.currentModeLabel(id)))")
                    fail(.modeNotApplied)
                }
            }
        }

        func waitForOnline() {
            let now = Date()
            if isDisplayOnline(id) {
                if onlineSince == nil { onlineSince = now }
                if now >= readyAt,
                   let onlineSince,
                   now.timeIntervalSince(onlineSince) >= 0.6 {
                    enforceMode()
                    return
                }
            } else {
                onlineSince = nil
            }

            if DispatchTime.now() >= deadline {
                NSLog("ResSwitch: display #\(id) never came online (current \(currentModeLabel(id)))")
                fail(.notOnline)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { waitForOnline() }
        }

        waitForOnline()
    }

    /// Apply the preset's mode from a freshly started copy of this executable.
    /// See the comment on `settle` for why this cannot be done in-process.
    private func applyModeExternally(
        _ id: CGDirectDisplayID,
        preset: Preset,
        mode: ScaleMode,
        completion: @escaping (Bool) -> Void
    ) {
        guard let executable = Bundle.main.executableURL else {
            completion(false)
            return
        }

        let helper = Process()
        helper.executableURL = executable
        helper.arguments = [
            "--set-mode",
            "\(id)",
            "\(preset.logicalWidth(for: mode))",
            "\(preset.logicalHeight(for: mode))",
            "\(preset.width)",
            "\(preset.height)"
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        helper.terminationHandler = { finished in
            let applied = finished.terminationStatus == 0
            DispatchQueue.main.async { completion(applied) }
        }

        do {
            try helper.run()
        } catch {
            NSLog("ResSwitch: could not launch mode helper: \(error.localizedDescription)")
            completion(false)
            return
        }

        // A wedged helper must not keep the switch pending forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if helper.isRunning { helper.terminate() }
        }
    }

    /// A virtual display can be online and usable while
    /// CGDisplayCopyDisplayMode still returns nil for it (observed on macOS
    /// 27 with a display created by the same non-GUI test process), so online
    /// is checked through both APIs.
    private func isDisplayOnline(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsOnline(id) != 0 || DisplayInfo.onlineIDs().contains(id)
    }

    private func currentModeLabel(_ id: CGDirectDisplayID) -> String {
        if let mode = DisplayInfo.currentMode(id) {
            return "\(mode.width)×\(mode.height)pt / \(mode.pixelWidth)×\(mode.pixelHeight)px"
        }
        return "unknown (online=\(CGDisplayIsOnline(id)), " +
            "\(CGDisplayPixelsWide(id))×\(CGDisplayPixelsHigh(id))px)"
    }

    // MARK: - Lifetime helpers

    /// Wall-clock based for now, but clamped to `minimumLifetime`: a backwards
    /// system-clock step must never turn a 2.5 s settle window into hours of
    /// "switching" state or a quit that never completes.
    private func remainingLifetime(for birth: Date) -> TimeInterval {
        let elapsed = Date().timeIntervalSince(birth)
        return min(minimumLifetime, max(0, minimumLifetime - elapsed))
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
