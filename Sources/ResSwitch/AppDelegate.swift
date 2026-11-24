import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = VirtualDisplayController.shared
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var detailMenuItem: NSMenuItem!
    private var presetItems: [String: NSMenuItem] = [:]
    private var scaleMenuItem: NSMenuItem!
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
                accessibilityDescription: "ResSwitch 虚拟显示器分辨率"
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

        statusMenuItem = infoItem("虚拟屏：未启用")
        menu.addItem(statusMenuItem)

        detailMenuItem = infoItem("选择下方分辨率即可创建")
        menu.addItem(detailMenuItem)

        menu.addItem(.separator())

        for preset in Preset.all {
            let title = preset.id == Preset.default.id
                ? "\(preset.menuTitle)（默认）"
                : preset.menuTitle
            let item = NSMenuItem(
                title: title,
                action: #selector(selectPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.id
            menu.addItem(item)
            presetItems[preset.id] = item
        }

        menu.addItem(.separator())

        scaleMenuItem = NSMenuItem(title: "缩放", action: nil, keyEquivalent: "")
        let scaleSubmenu = NSMenu()
        pointPerfectItem = NSMenuItem(
            title: ScaleMode.pointPerfect.title,
            action: #selector(selectPointPerfect),
            keyEquivalent: ""
        )
        pointPerfectItem.target = self
        scaleSubmenu.addItem(pointPerfectItem)

        hiDPIItem = NSMenuItem(
            title: ScaleMode.hiDPI.title + "（推荐）",
            action: #selector(selectHiDPI),
            keyEquivalent: ""
        )
        hiDPIItem.target = self
        scaleSubmenu.addItem(hiDPIItem)
        scaleMenuItem.submenu = scaleSubmenu
        menu.addItem(scaleMenuItem)

        menu.addItem(.separator())

        closeMenuItem = NSMenuItem(
            title: "关闭虚拟显示器",
            action: #selector(closeVirtualDisplay),
            keyEquivalent: ""
        )
        closeMenuItem.target = self
        menu.addItem(closeMenuItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "打开显示器设置…",
            action: #selector(openDisplaySettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let copyItem = NSMenuItem(
            title: "复制显示器信息",
            action: #selector(copyDisplayInfo),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 ResSwitch",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        quitItem = NSMenuItem(
            title: "退出 ResSwitch",
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
        let soleDisplay = controller.isSoleOnlineDisplay && controller.hasOnlineDisplay
        setInfo(
            statusMenuItem,
            controller.statusTitle,
            font: .systemFont(ofSize: 12, weight: .semibold),
            color: .labelColor
        )
        setInfo(
            detailMenuItem,
            controller.statusDetail,
            font: .systemFont(ofSize: 11, weight: .regular),
            color: .secondaryLabelColor
        )

        for preset in Preset.all {
            guard let item = presetItems[preset.id] else { continue }
            item.state = (controller.activePreset?.id == preset.id) ? .on : .off
            item.isEnabled = !locked
        }

        scaleMenuItem.title = "缩放：\(controller.scaleMode.shortTitle)"
        pointPerfectItem.state = (controller.scaleMode == .pointPerfect) ? .on : .off
        hiDPIItem.state = (controller.scaleMode == .hiDPI) ? .on : .off
        pointPerfectItem.isEnabled = !locked
        hiDPIItem.isEnabled = !locked

        closeMenuItem.isEnabled = controller.canClose
        closeMenuItem.title = soleDisplay ? "关闭虚拟显示器（唯一屏幕）" : "关闭虚拟显示器"
        quitItem.title = soleDisplay ? "退出 ResSwitch（唯一屏幕）" : "退出 ResSwitch"

        if let button = statusItem.button {
            button.appearsDisabled = locked
            let tooltip: String
            if let preset = controller.activePreset {
                let detail = preset.detailLabel(for: controller.activeScaleMode ?? controller.scaleMode)
                tooltip = soleDisplay
                    ? "ResSwitch\n\(preset.name) · \(detail)\n当前唯一屏幕：关闭或退出前会二次确认"
                    : "ResSwitch\n\(preset.name) · \(detail)"
            } else {
                tooltip = "ResSwitch\n虚拟显示器未启用"
            }
            button.toolTip = tooltip
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
            guard confirmSoleDisplayClose() else { return }
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

    private func confirmSoleDisplayClose() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "这是当前唯一的显示器"
        alert.informativeText = """
        关闭后，这台 Mac 将没有任何可用的屏幕，远程画面可能立即中断，而且无法在画面里重新打开。

        如果旁边没有物理显示器，请先接上物理屏，或确认远程工具能自行创建虚拟屏。
        """
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍要关闭")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func confirmSoleDisplayTermination() -> Bool {
        if isShowingSoleDisplayWarning { return false }
        isShowingSoleDisplayWarning = true
        defer { isShowingSoleDisplayWarning = false }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "这是当前唯一的显示器"
        alert.informativeText = """
        退出 ResSwitch 后，这台 Mac 将失去唯一的虚拟屏，远程画面可能立即中断，而且无法在画面里重新打开。

        如果旁边没有物理显示器，请先接上物理屏，或确认远程工具能自行创建虚拟屏。
        """
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍要退出")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func openDisplaySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSSound.beep()
    }

    @objc private func copyDisplayInfo() {
        let text = """
        ResSwitch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(controller.statusTitle)
        \(controller.statusDetail)

        \(DisplayInfo.dump())
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: """
            常驻菜单栏的虚拟显示器分辨率切换工具。
            使用 macOS 私有 CGVirtualDisplay 接口，不上传任何数据。

            预设：1080p / 2K / 4K / iPad Pro 2018 / MacBook Pro 16″ / 3440×1440
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "ResSwitch",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
            .credits: credits
        ]
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
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
        alert.informativeText = suggestion ?? "请稍后重试。"

        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
