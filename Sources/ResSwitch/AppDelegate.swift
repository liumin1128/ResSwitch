import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = VirtualDisplayController.shared
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var presetItems: [String: NSMenuItem] = [:]
    private var pointPerfectItem: NSMenuItem!
    private var hiDPIItem: NSMenuItem!
    private var closeMenuItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    private enum TerminationPhase {
        case idle
        case preparing
        case replied
    }

    private var terminationPhase: TerminationPhase = .idle
    private var soleDisplayWarningConfirmed = false
    private var isShowingSoleDisplayWarning = false
    private var systemIsPoweringOff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.stateDidChange = { [weak self] in
            self?.refreshMenu()
        }
        // Logout/shutdown must not be blocked by the sole-display warning.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        setupStatusItem()
        refreshMenu()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func systemWillPowerOff(_ notification: Notification) {
        systemIsPoweringOff = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch terminationPhase {
        case .replied:
            return .terminateNow

        case .preparing:
            // The first request is still waiting for displays to settle. Keep
            // deferring instead of returning .terminateNow, which would release
            // a display younger than the minimum lifetime.
            return .terminateLater

        case .idle:
            if !systemIsPoweringOff,
               !soleDisplayWarningConfirmed,
               controller.isSoleOnlineDisplay,
               controller.hasOnlineDisplay {
                guard confirmSoleDisplayTermination() else {
                    return .terminateCancel
                }
                soleDisplayWarningConfirmed = true
            }

            terminationPhase = .preparing
            // Logout/shutdown should not wait as long as an explicit quit.
            let timeout: TimeInterval = systemIsPoweringOff ? 3.0 : 8.0
            controller.prepareForTermination(timeout: timeout) { [weak self] in
                guard let self else { return }
                self.terminationPhase = .replied
                DispatchQueue.main.async {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: "ResSwitch"
            )
            if let image {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageOnly
            } else {
                button.title = "R"
            }
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        statusMenuItem = infoItem("No virtual display")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        for preset in Preset.all {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(selectPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id
            menu.addItem(item)
            presetItems[preset.id] = item
        }

        menu.addItem(.separator())

        let scaleMenuItem = NSMenuItem(title: "Scale", action: nil, keyEquivalent: "")
        let scaleSubmenu = NSMenu()
        pointPerfectItem = NSMenuItem(
            title: ScaleMode.pointPerfect.title,
            action: #selector(selectPointPerfect),
            keyEquivalent: ""
        )
        pointPerfectItem.target = self
        scaleSubmenu.addItem(pointPerfectItem)

        hiDPIItem = NSMenuItem(
            title: ScaleMode.hiDPI.title,
            action: #selector(selectHiDPI),
            keyEquivalent: ""
        )
        hiDPIItem.target = self
        scaleSubmenu.addItem(hiDPIItem)
        scaleMenuItem.submenu = scaleSubmenu
        menu.addItem(scaleMenuItem)

        menu.addItem(.separator())

        closeMenuItem = NSMenuItem(
            title: "Close Virtual Display",
            action: #selector(closeVirtualDisplay),
            keyEquivalent: ""
        )
        closeMenuItem.target = self
        menu.addItem(closeMenuItem)

        menu.addItem(.separator())

        quitItem = NSMenuItem(
            title: "Quit ResSwitch",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        controller.refreshState()
        refreshMenu()
    }

    private func refreshMenu() {
        guard statusItem != nil, quitItem != nil else { return }

        let locked = controller.isBusy || controller.isTerminating
        setInfo(
            statusMenuItem,
            controller.statusTitle,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )

        for preset in Preset.all {
            guard let item = presetItems[preset.id] else { continue }
            item.state = (controller.activePreset?.id == preset.id) ? .on : .off
            item.isEnabled = !locked
        }

        pointPerfectItem.state = (controller.scaleMode == .pointPerfect) ? .on : .off
        hiDPIItem.state = (controller.scaleMode == .hiDPI) ? .on : .off
        pointPerfectItem.isEnabled = !locked
        hiDPIItem.isEnabled = !locked

        closeMenuItem.isEnabled = controller.canClose

        if let button = statusItem.button {
            button.appearsDisabled = locked
        }
    }

    private func setInfo(
        _ item: NSMenuItem,
        _ title: String,
        font: NSFont,
        color: NSColor
    ) {
        item.title = title
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .foregroundColor: color
            ]
        )
    }

    // MARK: - Actions

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let preset = Preset.preset(id: id) else {
            return
        }

        controller.apply(preset) { [weak self] result in
            if case .failure(let error) = result {
                self?.present(error: error)
            }
        }
    }

    @objc private func selectPointPerfect() {
        setScaleMode(.pointPerfect)
    }

    @objc private func selectHiDPI() {
        setScaleMode(.hiDPI)
    }

    private func setScaleMode(_ mode: ScaleMode) {
        controller.setScaleMode(mode) { [weak self] result in
            if case .failure(let error) = result {
                self?.present(error: error)
            }
        }
    }

    @objc private func closeVirtualDisplay() {
        requestClose(allowingSoleDisplay: false)
    }

    private func requestClose(allowingSoleDisplay: Bool) {
        if !allowingSoleDisplay, controller.isSoleOnlineDisplay, controller.hasOnlineDisplay {
            guard confirmSoleDisplay(action: "Close Anyway") else { return }
            requestClose(allowingSoleDisplay: true)
            return
        }

        controller.disable(allowingSoleDisplay: allowingSoleDisplay) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                if let vdError = error as? VirtualDisplayError {
                    switch vdError {
                    case .lastDisplay:
                        // State changed between the check and the call; ask
                        // again instead of silently closing the last screen.
                        self.requestClose(allowingSoleDisplay: false)
                    case .busy, .terminating:
                        break
                    default:
                        self.present(error: error)
                    }
                } else {
                    self.present(error: error)
                }
            }
        }
    }

    private func confirmSoleDisplayTermination() -> Bool {
        if isShowingSoleDisplayWarning { return false }
        isShowingSoleDisplayWarning = true
        defer { isShowingSoleDisplayWarning = false }
        return confirmSoleDisplay(action: "Quit Anyway")
    }

    private func confirmSoleDisplay(action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This is the only display"
        alert.informativeText = "This Mac will have no screen, and you may not be able to restore it remotely."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func quit() {
        // An explicit Quit (menu or Cmd+Q) is not a system logout. Clear a
        // stale power-off flag so the sole-display warning still appears if a
        // previous logout was cancelled.
        systemIsPoweringOff = false
        NSApp.terminate(nil)
    }

    private func present(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription

        let suggestion = (error as? LocalizedError)?.recoverySuggestion
        alert.informativeText = suggestion ?? "Try again."

        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
