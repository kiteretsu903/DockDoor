#if DEBUG
    import Cocoa
    import Defaults

    final class DebugTestHarness {
        struct Hooks {
            var simulateWake: () -> Void
            var resetKeybind: () -> Void
            var switcherSessionActive: () -> Bool
            var previewVisible: () -> Bool
            var previewWindowCount: () -> Int
        }

        private static let prefix = "com.ethanbills.DockDoor.debug."
        private static let diagnosticsLog = "/tmp/DockDoor-Diagnostics.log"
        private static let memoryLog = "/tmp/DockDoor-Memory.log"
        private static let settingsLog = "/tmp/DockDoor-Settings.log"
        private static let refreshLog = "/tmp/DockDoor-FullRefresh.log"

        private let hooks: Hooks
        private var observers: [NSObjectProtocol] = []

        init(hooks: Hooks) {
            self.hooks = hooks
            let center = DistributedNotificationCenter.default()
            let handlers: [(String, (Notification) -> Void)] = [
                ("memorySnapshot", { [weak self] _ in self?.writeMemorySnapshot() }),
                ("toggleDefault", { n in Self.toggleDefault(n.object as? String) }),
                ("setDefault", { n in Self.setDefault(n.object as? String) }),
                ("settingsQuery", { _ in Self.writeSettings() }),
                ("diagnostics", { [weak self] _ in self?.writeDiagnostics() }),
                ("fullRefresh", { _ in Self.runFullRefresh() }),
                ("purgeCache", { _ in WindowUtil.purgeAllCaches() }),
                ("simulateWake", { [weak self] _ in self?.hooks.simulateWake() }),
                ("resetKeybind", { [weak self] _ in self?.hooks.resetKeybind() }),
                ("previewInputPlan", { n in
                    let plan = n.object as? String
                    Task { @MainActor in DebugPreviewRaceProbe.runInputPlan(plan) }
                }),
                ("previewInputTargets", { _ in
                    Task { @MainActor in DebugPreviewRaceProbe.writeInputTargets() }
                }),
            ]
            for (name, handler) in handlers {
                let token = center.addObserver(forName: Notification.Name(Self.prefix + name), object: nil, queue: .main, using: handler)
                observers.append(token)
            }
            Task { @MainActor in
                DebugPreviewRaceProbe.scheduleControlledScenarioIfRequested()
            }
        }

        deinit {
            let center = DistributedNotificationCenter.default()
            for token in observers {
                center.removeObserver(token)
            }
        }

        private static func write(_ text: String, to path: String, append: Bool = false) {
            guard let data = (text + "\n").data(using: .utf8) else { return }
            if append, let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }

        private static func residentBytes() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        private static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            return user + system
        }

        private static func eventTapStats() -> [[String: Any]] {
            var count: UInt32 = 0
            CGGetEventTapList(0, nil, &count)
            var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
            CGGetEventTapList(count, &taps, &count)
            let pid = ProcessInfo.processInfo.processIdentifier
            return taps.prefix(Int(count)).filter { $0.tappingProcess == pid }.map { tap in
                [
                    "id": tap.eventTapID,
                    "enabled": tap.enabled,
                    "point": tap.tapPoint.rawValue,
                    "avgUsec": tap.avgUsecLatency,
                    "maxUsec": tap.maxUsecLatency,
                ]
            }
        }

        private func writeMemorySnapshot() {
            Self.write("\(Date().timeIntervalSince1970) \(Self.residentBytes())", to: Self.memoryLog, append: true)
        }

        private func writeDiagnostics() {
            let taps = Self.eventTapStats()
            let payload: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "rss": Self.residentBytes(),
                "cpuSeconds": Self.cpuSeconds(),
                "cachedWindows": WindowUtil.cachedWindowCount(),
                "cachedApps": WindowUtil.cachedAppCount(),
                "eventTaps": taps,
                "enabledTaps": taps.filter { ($0["enabled"] as? Bool) == true }.count,
                "disabledTaps": taps.filter { ($0["enabled"] as? Bool) == false }.count,
                "switcherSessionActive": hooks.switcherSessionActive(),
                "previewVisible": hooks.previewVisible(),
                "previewWindowCount": hooks.previewWindowCount(),
                "keybind": ["keyCode": Defaults[.UserKeybind].keyCode, "modifierFlags": Defaults[.UserKeybind].modifierFlags],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) {
                Self.write(json, to: Self.diagnosticsLog)
            }
        }

        private static func writeSettings() {
            let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            let serializable = domain.filter { JSONSerialization.isValidJSONObject([$0.value]) }
            if let data = try? JSONSerialization.data(withJSONObject: serializable), let json = String(data: data, encoding: .utf8) {
                write(json, to: settingsLog)
            }
        }

        private static func toggleDefault(_ key: String?) {
            guard let key else { return }
            let current = UserDefaults.standard.bool(forKey: key)
            UserDefaults.standard.set(!current, forKey: key)
        }

        private static func setDefault(_ payload: String?) {
            guard let payload, let separator = payload.firstIndex(of: "=") else { return }
            let key = String(payload[..<separator])
            let raw = String(payload[payload.index(after: separator)...])
            let defaults = UserDefaults.standard
            if raw == "true" || raw == "false" {
                defaults.set(raw == "true", forKey: key)
            } else if let int = Int(raw) {
                defaults.set(int, forKey: key)
            } else if let double = Double(raw) {
                defaults.set(double, forKey: key)
            } else {
                defaults.set(raw, forKey: key)
            }
        }

        private static func runFullRefresh() {
            Task {
                let start = CFAbsoluteTimeGetCurrent()
                let cpuStart = cpuSeconds()
                await WindowUtil.updateAllWindowsInCurrentSpace()
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                let cpu = cpuSeconds() - cpuStart
                write("\(Date().timeIntervalSince1970) ms=\(Int(elapsed)) cpuSeconds=\(String(format: "%.3f", cpu)) windows=\(WindowUtil.cachedWindowCount())", to: refreshLog, append: true)
            }
        }
    }

    @MainActor
    enum DebugPreviewRaceProbe {
        private static let mode = ProcessInfo.processInfo.environment["DOCKDOOR_PREVIEW_RACE"] ?? ""
        private static let startedAt = ProcessInfo.processInfo.systemUptime
        private static let logURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("DockDoor-PreviewRace-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString).jsonl")
        private static let logQueue = DispatchQueue(label: "DockDoor.PreviewRaceLog")
        private static var controlledRequestID: UUID?
        private static var announcedLog = false
        private static var driverRunning = false
        private static var inputPlanRunning = false

        static var isEnabled: Bool { mode == "observe" || mode == "controlled" }
        static var isControlled: Bool { mode == "controlled" }
        private static var inputEnabled: Bool { mode == "observe" && ProcessInfo.processInfo.environment["DOCKDOOR_PREVIEW_INPUT"] == "1" }

        private struct InputStep: Decodable {
            let action: String
            let x: Double?
            let y: Double?
            let wait: Double?
        }

        static func runInputPlan(_ json: String?) {
            guard inputEnabled, !inputPlanRunning, let data = json?.data(using: .utf8),
                  let steps = try? JSONDecoder().decode([InputStep].self, from: data),
                  (1 ... 120).contains(steps.count), steps.reduce(0, { $0 + ($1.wait ?? 0) }) <= 30,
                  steps.allSatisfy({ step in
                      let delay = step.wait ?? 0
                      return ["move", "escape", "wait"].contains(step.action) && delay.isFinite && (0 ... 5).contains(delay)
                          && (step.action != "move" || (step.x.map { $0.isFinite && abs($0) <= 20000 } == true
                                  && step.y.map { $0.isFinite && abs($0) <= 20000 } == true))
                  })
            else { return }
            let coordinator = SharedPreviewWindowCoordinator.activeInstance
            guard CGPreflightPostEventAccess() else {
                record("input.permissionMissing", coordinator: coordinator)
                return
            }
            inputPlanRunning = true
            Task { @MainActor in
                defer { inputPlanRunning = false }
                record("input.planStarted", coordinator: coordinator)
                for step in steps {
                    if step.action == "move", let x = step.x, let y = step.y {
                        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
                        record("input.move", coordinator: coordinator)
                    } else if step.action == "escape" {
                        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                        record("input.escape", coordinator: coordinator)
                    }
                    try? await Task.sleep(nanoseconds: UInt64((step.wait ?? 0) * 1_000_000_000))
                }
                record("input.planCompleted", coordinator: coordinator)
            }
        }

        static func writeInputTargets() {
            guard inputEnabled else { return }
            func rect(_ frame: CGRect) -> [String: CGFloat] {
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            var payload: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                          "inputPermission": CGPreflightPostEventAccess(),
                                          "screens": NSScreen.screens.map { rect($0.cgFrame) }]
            if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
               let list = try? AXUIElementCreateApplication(dockApp.processIdentifier).children()?
               .first(where: { (try? $0.role()) == kAXListRole }), let items = try? list.children()
            {
                payload["dockItems"] = items.compactMap { item -> [String: Any]? in
                    guard let name = try? item.title(), ["Xcode", "Calculator", "TextEdit", "Finder"].contains(name),
                          let position = try? item.position(), let size = try? item.size() else { return nil }
                    return ["name": name, "frame": rect(CGRect(origin: position, size: size))]
                }
            }
            if let coordinator = SharedPreviewWindowCoordinator.activeInstance, coordinator.isVisible,
               let desktopTop = NSScreen.screens.first?.frame.maxY
            {
                let frame = coordinator.frame
                payload["parentFrame"] = rect(CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height))
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/DockDoor-InputTargets.json"), options: .atomic)
            }
        }

        static func scheduleControlledScenarioIfRequested() {
            guard isEnabled else { return }
            let coordinator = SharedPreviewWindowCoordinator.activeInstance
            record(inputEnabled ? "session.observeWithInput" : "session.\(mode)", coordinator: coordinator)
            record(AXIsProcessTrusted() ? "permissions.accessibilityGranted" : "permissions.accessibilityMissing", coordinator: coordinator)
            record(CGPreflightScreenCaptureAccess() ? "permissions.screenCaptureGranted" : "permissions.screenCaptureMissing", coordinator: coordinator)
            guard mode == "controlled", ProcessInfo.processInfo.environment["DOCKDOOR_PREVIEW_RACE_AUTOSTART"] == "1" else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let coordinator = SharedPreviewWindowCoordinator.activeInstance
                record(AXIsProcessTrusted() ? "permissions.accessibilityGranted" : "permissions.accessibilityMissing", coordinator: coordinator)
                record(CGPreflightScreenCaptureAccess() ? "permissions.screenCaptureGranted" : "permissions.screenCaptureMissing", coordinator: coordinator)
                runFromDebugger()
            }
        }

        static func runFromDebugger() {
            guard mode == "controlled", !driverRunning, controlledRequestID == nil,
                  let coordinator = SharedPreviewWindowCoordinator.activeInstance
            else { return }
            let windows = WindowUtil.getAllWindowsOfAllApps()
            guard let window = windows.first(where: {
                $0.app.bundleIdentifier == "com.apple.dt.Xcode"
                    && !$0.isWindowlessApp && !$0.isMinimized && !$0.isHidden && $0.image != nil
                    && (try? $0.axElement.position()) != nil
            }), let screen = NSScreen.main else {
                record("controlled.noEligibleWindow", coordinator: coordinator)
                return
            }
            driverRunning = true
            Task { @MainActor in
                defer { driverRunning = false }
                // Drain activation notifications accumulated while the debugger was paused.
                try? await Task.sleep(nanoseconds: 500_000_000)
                record("controlled.driver", coordinator: coordinator, windowID: window.id)
                coordinator.showWindow(appName: window.app.localizedName ?? "Preview test", windows: [window],
                                       mouseLocation: NSEvent.mouseLocation, mouseScreen: screen, dockItemElement: nil,
                                       overrideDelay: true, bypassDockMouseValidation: true, dockPositionOverride: .cli)
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard coordinator.isVisible else {
                    record("controlled.parentNotShown", coordinator: coordinator)
                    return
                }
                guard let hoverID = coordinator.beginFullPreviewHover() else { return }
                coordinator.showWindow(appName: window.app.localizedName ?? "Preview test", windows: [window],
                                       mouseScreen: screen, dockItemElement: nil, overrideDelay: true,
                                       centeredHoverWindowState: .fullWindowPreview, fullPreviewHoverID: hoverID)
            }
        }

        static func record(_ event: String, coordinator: SharedPreviewWindowCoordinator?, requestID: UUID? = nil,
                           windowID: CGWindowID? = nil, hoverID: UUID? = nil)
        {
            guard isEnabled else { return }
            if !announcedLog {
                announcedLog = true
                print("Preview race diagnostic: \(mode), log: \(logURL.path)")
            }
            let timestamp = ProcessInfo.processInfo.systemUptime
            let mouseLocation = NSEvent.mouseLocation
            var payload: [String: Any] = [
                "event": event,
                "elapsed": max(0, timestamp - startedAt),
                "wallTime": Date().timeIntervalSince1970,
                "mode": mode,
                "parentVisible": coordinator?.isVisible ?? false,
                "fullPreviewVisible": coordinator?.tapSnapshot.fullPreviewFrame != nil,
                "mouseWithinParent": coordinator?.mouseIsWithinPreviewWindow ?? false,
                "windowCount": coordinator?.windowSwitcherCoordinator.windows.count ?? 0,
                "mouseInsideParentFrame": coordinator?.frame.contains(mouseLocation) ?? false,
                "mouseInsideFullFrame": coordinator?.tapSnapshot.fullPreviewFrame?.contains(mouseLocation) ?? false,
                "switcherActive": coordinator?.windowSwitcherCoordinator.windowSwitcherActive ?? false,
                "parentAlpha": coordinator?.alphaValue ?? 0,
            ]
            if let requestID { payload["requestID"] = requestID.uuidString }
            if let windowID { payload["windowID"] = windowID }
            if let hoverID { payload["hoverID"] = hoverID.uuidString }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            let line = data + Data([0x0A])
            let destination = logURL
            logQueue.async {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    FileManager.default.createFile(atPath: destination.path, contents: nil)
                }
                do {
                    let handle = try FileHandle(forWritingTo: destination)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } catch {
                    print("Preview race log write failed: \(error)")
                }
            }
        }

        static func pauseBeforeDisplay(coordinator: SharedPreviewWindowCoordinator, requestID: UUID?) async -> Bool {
            guard mode == "controlled", let requestID, controlledRequestID == nil,
                  coordinator.isVisible, !coordinator.windowSwitcherCoordinator.windowSwitcherActive
            else { return false }

            controlledRequestID = requestID
            record("controlled.pause", coordinator: coordinator, requestID: requestID)
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                record("controlled.dismissParent", coordinator: coordinator, requestID: requestID)
                coordinator.hideWindow()
                // Drain thumbnail teardown and hover-exit callbacks before releasing the stale request.
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                record("controlled.interrupted", coordinator: coordinator, requestID: requestID)
            }
            record("controlled.resume", coordinator: coordinator, requestID: requestID)
            return true
        }

        static func inspectAndCleanup(coordinator: SharedPreviewWindowCoordinator, requestID: UUID?) async {
            try? await Task.sleep(nanoseconds: 300_000_000)
            let orphanAppeared = !coordinator.isVisible && coordinator.tapSnapshot.fullPreviewFrame != nil
            record(orphanAppeared ? "controlled.orphanObserved" : "controlled.orphanNotObserved",
                   coordinator: coordinator, requestID: requestID)
            guard orphanAppeared else { return }

            coordinator.hideWindow()
            let survivedHide = !coordinator.isVisible && coordinator.tapSnapshot.fullPreviewFrame != nil
            record(survivedHide ? "controlled.survivedHide" : "controlled.dismissed",
                   coordinator: coordinator, requestID: requestID)
            // Leave a bounded interval for visual inspection, then remove only an orphaned child.
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !coordinator.isVisible {
                coordinator.hideFullPreviewWindow()
            }
            record("controlled.cleanup", coordinator: coordinator, requestID: requestID)
        }
    }
#endif
