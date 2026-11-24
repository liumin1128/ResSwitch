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
    private var didPrepareToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller.stateDidChange = { [weak self] in
            self?.refreshMenu()
        }
        setupStatusItem()
        refreshMenu()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if didPrepareToTerminate {
            return .terminateNow
        }
        didPrepareToTerminate = true
        controller.prepareForTermination {
            DispatchQueue.main.async {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
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
            title: ScaleMode.pointPerfect.title + "（推荐，1:1）",
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

        let quitItem = NSMenuItem(
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
        guard statusItem != nil else { return }

        let busy = controller.isBusy
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
            item.isEnabled = !busy
        }

        scaleMenuItem.title = "缩放：\(controller.scaleMode.shortTitle)"
        pointPerfectItem.state = (controller.scaleMode == .pointPerfect) ? .on : .off
        hiDPIItem.state = (controller.scaleMode == .hiDPI) ? .on : .off
        pointPerfectItem.isEnabled = !busy
        hiDPIItem.isEnabled = !busy

        closeMenuItem.isEnabled = controller.canClose

        if let button = statusItem.button {
            button.appearsDisabled = busy
            let tooltip: String
            if let preset = controller.activePreset {
                let detail = preset.detailLabel(for: controller.activeScaleMode ?? controller.scaleMode)
                tooltip = "ResSwitch\n\(preset.name) · \(detail)"
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
        controller.disable { [weak self] result in
            if case .failure(let error) = result {
                self?.present(error: error)
            }
        }
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
