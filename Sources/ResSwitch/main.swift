import AppKit
import Foundation

private let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("ResSwitch 1.0.4")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        ResSwitch — macOS 菜单栏虚拟显示器分辨率切换工具

        用法：
          ResSwitch                 启动菜单栏 App
          ResSwitch --list          只读打印当前显示器与所有模式
          ResSwitch --selftest      创建一块默认 1080p 虚拟屏，3 秒后释放
          ResSwitch --selftest 4k   指定预设进行自检（1080p/2k/4k/ipad/mbp16/3440）
          ResSwitch --selftest 4k --hold 8  自检并保持 8 秒
          ResSwitch --selftest-switch  连续切换 iPad → 4K 后释放
          ResSwitch --version       打印版本

        --list 与 --selftest 不会启动菜单栏界面。
        """
    )
    exit(0)
}

if arguments.contains("--list") {
    print("ResSwitch 显示器信息")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("")
    print(DisplayInfo.dump())
    exit(0)
}

if arguments.contains("--selftest-switch") {
    runSwitchTest()
}

if let selfTestIndex = arguments.firstIndex(of: "--selftest") {
    let presetID: String
    if selfTestIndex + 1 < arguments.count, !arguments[selfTestIndex + 1].hasPrefix("-") {
        presetID = arguments[selfTestIndex + 1]
    } else {
        presetID = Preset.default.id
    }

    var hold: TimeInterval = 0
    if let holdIndex = arguments.firstIndex(of: "--hold"),
       holdIndex + 1 < arguments.count,
       let value = TimeInterval(arguments[holdIndex + 1]) {
        hold = max(0, value)
    }

    runSelfTest(presetID: presetID, hold: hold)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

// MARK: - Self test

private func runSelfTest(presetID: String, hold: TimeInterval) -> Never {
    guard let preset = Preset.preset(id: presetID) else {
        print("❌ 未知预设：\(presetID)（可选 1080p / 2k / 4k / ipad / mbp16 / 3440）")
        exit(2)
    }

    let controller = VirtualDisplayController.shared

    print("ResSwitch 自检")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("预设：\(preset.name)  \(preset.pixelLabel)  \(preset.detailLabel(for: controller.scaleMode))")
    print("")
    print("== 创建前")
    print(DisplayInfo.dump())
    print("")
    var finished = false
    var succeeded = false

    controller.apply(preset) { result in
        switch result {
        case .success:
            print("✅ 虚拟屏已创建并切换到 \(preset.pixelLabel)")
            print("")
            print("== 创建后")
            print(DisplayInfo.dump())
            print("")
            if hold > 0 {
                print("… 保持 \(Int(hold)) 秒（方便外部观察）")
            } else {
                print("… 等待释放")
            }
            let release = {
                controller.disable { disableResult in
                    switch disableResult {
                    case .success:
                        print("✅ 虚拟屏已释放")
                        succeeded = true
                    case .failure(let error):
                        print("❌ 释放失败：\(error.localizedDescription)")
                    }
                    finished = true
                }
            }
            if hold > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: release)
            } else {
                release()
            }
        case .failure(let error):
            print("❌ 创建失败：\(error.localizedDescription)")
            if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
                print("   \(suggestion)")
            }
            controller.disable { _ in
                finished = true
            }
        }
    }

    let deadline = Date().addingTimeInterval(25)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    print("")
    print("== 结束后")
    print(DisplayInfo.dump())

    if !finished {
        print("❌ 自检超时")
        exit(1)
    }
    exit(succeeded ? 0 : 1)
}


private func runSwitchTest() -> Never {
    let presets = [Preset.default, Preset.preset(id: "4k")!]
    let controller = VirtualDisplayController.shared
    var allOK = true

    print("ResSwitch 连续切换自检")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("")

    for preset in presets {
        print("== 切换到 \(preset.name) \(preset.pixelLabel)")
        var finished = false
        var failure: Error?
        controller.apply(preset) { result in
            if case .failure(let error) = result { failure = error }
            finished = true
        }

        let deadline = Date().addingTimeInterval(15)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        if !finished {
            print("❌ 切换超时")
            allOK = false
            break
        }
        if let failure {
            print("❌ 切换失败：\(failure.localizedDescription)")
            allOK = false
            break
        }

        print("✅ 已切换到 \(preset.pixelLabel)")
        print(DisplayInfo.dump())
        print("")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    print("== 关闭虚拟显示器")
    var finished = false
    controller.disable { result in
        if case .failure(let error) = result {
            print("❌ 关闭失败：\(error.localizedDescription)")
            allOK = false
        } else {
            print("✅ 已关闭")
        }
        finished = true
    }

    let deadline = Date().addingTimeInterval(12)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !finished {
        print("❌ 关闭超时")
        allOK = false
    }

    print("")
    print("== 结束后")
    print(DisplayInfo.dump())
    exit(allOK ? 0 : 1)
}
