import AppKit
import Foundation

private let arguments = CommandLine.arguments

if arguments.contains("--version") {
    print("ResSwitch 1.0.7")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        ResSwitch — virtual display switcher for macOS

        Usage:
          ResSwitch                    Run the menu bar app
          ResSwitch --list             Print online displays and modes
          ResSwitch --selftest [id]    Create a test display, then release it
          ResSwitch --selftest [id] --hold <seconds>
                                       Keep the test display for a while
          ResSwitch --selftest-switch  Switch iPad → 4K, then release
          ResSwitch --version          Print version

        Presets: 1080p, 2k, 4k, 5k, ipad, mbp16, 3440
        """
    )
    exit(0)
}

if arguments.contains("--list") {
    print("ResSwitch display list")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("")
    print(DisplayInfo.dump())
    exit(0)
}

if let index = arguments.firstIndex(of: "--set-mode") {
    runSetMode(arguments, at: index)
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
        print("❌ Unknown preset: \(presetID) (use 1080p, 2k, 4k, 5k, ipad, mbp16, or 3440)")
        exit(2)
    }

    let controller = VirtualDisplayController.shared
    let scale = preset.usesHiDPI(for: controller.scaleMode) ? "2×" : "1×"

    print("ResSwitch self-test")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Preset: \(preset.name)  \(preset.pixelLabel)  \(scale)")
    print("")
    print("== Before")
    print(DisplayInfo.dump())
    print("")
    var finished = false
    var succeeded = false

    controller.apply(preset) { result in
        switch result {
        case .success:
            print("✅ Virtual display ready at \(preset.pixelLabel)")
            print("")
            print("== Created")
            print(DisplayInfo.dump())
            print("")
            if hold > 0 {
                print("… holding for \(Int(hold))s")
            } else {
                print("… releasing")
            }
            let release = {
                controller.disable(allowingSoleDisplay: true) { disableResult in
                    switch disableResult {
                    case .success:
                        print("✅ Virtual display released")
                        succeeded = true
                    case .failure(let error):
                        print("❌ Release failed: \(error.localizedDescription)")
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
            print("❌ Create failed: \(error.localizedDescription)")
            if let suggestion = (error as? LocalizedError)?.recoverySuggestion {
                print("   \(suggestion)")
            }
            controller.disable(allowingSoleDisplay: true) { _ in
                finished = true
            }
        }
    }

    let deadline = Date().addingTimeInterval(25)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    print("")
    print("== After release")
    print(DisplayInfo.dump())

    if !finished {
        print("❌ Self-test timed out")
        exit(1)
    }
    exit(succeeded ? 0 : 1)
}


private func runSwitchTest() -> Never {
    let presets = [Preset.default, Preset.preset(id: "4k")!]
    let controller = VirtualDisplayController.shared
    var allOK = true

    print("ResSwitch switch test")
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("")

    for preset in presets {
        print("== Switch to \(preset.name) \(preset.pixelLabel)")
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
            print("❌ Switch timed out")
            allOK = false
            break
        }
        if let failure {
            print("❌ Switch failed: \(failure.localizedDescription)")
            allOK = false
            break
        }

        print("✅ Switched to \(preset.pixelLabel)")
        print(DisplayInfo.dump())
        print("")
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    }

    print("== Close virtual display")
    var finished = false
    controller.disable(allowingSoleDisplay: true) { result in
        if case .failure(let error) = result {
            print("❌ Close failed: \(error.localizedDescription)")
            allOK = false
        } else {
            print("✅ Closed")
        }
        finished = true
    }

    let deadline = Date().addingTimeInterval(12)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !finished {
        print("❌ Close timed out")
        allOK = false
    }

    print("")
    print("== After release")
    print(DisplayInfo.dump())
    exit(allOK ? 0 : 1)
}

// MARK: - Display mode helper

/// `ResSwitch --set-mode <displayID> <logicalW> <logicalH> <pixelW> <pixelH>`
///
/// Started by `VirtualDisplayController` after a virtual display comes online.
/// A fresh process is used because a process that has already queried displays
/// before creating a virtual display cannot read that display's mode list
/// (macOS 26/27 quirk), while a new process can.
///
/// Exit codes: 0 applied, 2 mode not found, 3 mode did not stick,
/// 4 display offline, 5 configuration rejected.
private func runSetMode(_ arguments: [String], at index: Int) -> Never {
    guard arguments.count > index + 5,
          let displayID = CGDirectDisplayID(arguments[index + 1]),
          let logicalWidth = Int(arguments[index + 2]),
          let logicalHeight = Int(arguments[index + 3]),
          let pixelWidth = Int(arguments[index + 4]),
          let pixelHeight = Int(arguments[index + 5]) else {
        exit(2)
    }

    func matches(_ mode: CGDisplayMode) -> Bool {
        mode.width == logicalWidth &&
            mode.height == logicalHeight &&
            mode.pixelWidth == pixelWidth &&
            mode.pixelHeight == pixelHeight
    }

    // Read the mode list before any other display query: that is the call the
    // creating process cannot make reliably. The duplicate-mode option is
    // required to see the 2x variants of the "looks like" sizes.
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
        exit(2)
    }
    guard CGDisplayIsOnline(displayID) != 0 else {
        exit(4)
    }
    if let current = CGDisplayCopyDisplayMode(displayID), matches(current) {
        exit(0)
    }
    guard let target = modes.first(where: matches) else {
        exit(2)
    }

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success,
          let config else {
        exit(5)
    }
    guard CGConfigureDisplayWithDisplayMode(config, displayID, target, nil) == .success else {
        CGCancelDisplayConfiguration(config)
        exit(5)
    }
    guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
        exit(5)
    }

    Thread.sleep(forTimeInterval: 0.3)
    if let current = CGDisplayCopyDisplayMode(displayID), matches(current) {
        exit(0)
    }
    exit(3)
}
