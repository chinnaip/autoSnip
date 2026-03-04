import Cocoa
import ScreenCaptureKit
import Carbon.HIToolbox
import Vision

func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a.lowercased()), b = Array(b.lowercased())
    var d = (0...b.count).map { $0 }
    for i in 1...a.count {
        var prev = d[0]; d[0] = i
        for j in 1...b.count {
            let temp = d[j]
            d[j] = a[i-1] == b[j-1] ? prev : 1 + min(prev, d[j], d[j-1])
            prev = temp
        }
    }
    return d[b.count]
}

func ocrMatches(_ ocr: String, _ target: String) -> Bool {
    // Must be similar length to avoid false positives from substrings or long chat text
    guard ocr.count >= max(3, target.count - 3),
          abs(ocr.count - target.count) <= 2 else { return false }
    return levenshtein(ocr.lowercased(), target.lowercased()) <= 2
}

func dbg(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: "/tmp/autosnip_debug.txt") {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? line.write(toFile: "/tmp/autosnip_debug.txt", atomically: false, encoding: .utf8)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {

    private var statusItem: NSStatusItem?
    private var anchorWindow: NSWindow?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupCarbonHotkey()
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "autoSnip")
        }

        let menu = NSMenu()

        let deviceName = UserDefaults.standard.string(forKey: "airDropDeviceName") ?? "Not set"
        let infoItem = NSMenuItem(title: "AirDrop device: \(deviceName)", action: nil, keyEquivalent: "")
        infoItem.isEnabled = false
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        let setDevice = NSMenuItem(title: "Set AirDrop Device...", action: #selector(setAirDropDevice), keyEquivalent: "")
        setDevice.target = self
        menu.addItem(setDevice)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit autoSnip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func refreshMenuBar() {
        guard let menu = statusItem?.menu else { return }
        let deviceName = UserDefaults.standard.string(forKey: "airDropDeviceName") ?? "Not set"
        menu.item(at: 0)?.title = "AirDrop device: \(deviceName)"
    }

    @objc private func setAirDropDevice() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set AirDrop Device"
        alert.informativeText = "Enter the exact name of the AirDrop device as it appears in the share sheet (case-sensitive)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "airDropDeviceName") ?? ""
        field.placeholderString = "e.g. John's iPhone"
        alert.accessoryView = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                UserDefaults.standard.set(name, forKey: "airDropDeviceName")
                refreshMenuBar()
            }
        }
    }

    // MARK: Carbon Hotkey (no Accessibility permission required)

    func setupCarbonHotkey() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Install Carbon event handler for hotkey press
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                dbg("hotkey_fired")
                delegate.captureAndShare()
                return noErr
            },
            1, &eventSpec, selfPtr, &hotKeyHandler
        )

        // Register Cmd+Shift+4
        // Carbon modifier values: cmdKey = 1<<8 = 256, shiftKey = 1<<9 = 512
        var hotKeyID = EventHotKeyID(signature: OSType(0x61754853), id: UInt32(1)) // 'auHS'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_4),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )

        dbg(status == noErr ? "hotkey_registered OK" : "hotkey_FAILED status=\(status)")
    }

    // MARK: Screen Capture

    func captureAndShare() {
        dbg("captureAndShare_start")

        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let content = content, error == nil else {
                dbg("SCShareableContent_error: \(error?.localizedDescription ?? "unknown")")
                return
            }

            guard let display = content.displays.first else {
                NSLog("autoSnip: no displays found")
                return
            }
            dbg("capturing_display \(display.width)x\(display.height)")

            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(Double(display.width) * scale)
            config.height = Int(Double(display.height) * scale)
            config.scalesToFit = true
            config.showsCursor = false

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { cgImage, captureError in
                guard let cgImage = cgImage, captureError == nil else {
                    dbg("capture_error: \(captureError?.localizedDescription ?? "unknown")")
                    return
                }
                dbg("capture_success")
                // Ensure AppKit calls happen on main thread
                DispatchQueue.main.async {
                    self?.saveAndShare(cgImage: cgImage)
                }
            }
        }
    }

    private func saveAndShare(cgImage: CGImage) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = URL(fileURLWithPath: "/tmp/autoSnip_\(timestamp).png")

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSLog("autoSnip: failed to create PNG data")
            return
        }

        do {
            try data.write(to: url)
            dbg("saved_to \(url.path)")
            shareViaAirDrop(fileURL: url)
        } catch {
            dbg("write_error: \(error.localizedDescription)")
        }
    }

    // MARK: AirDrop

    private func shareViaAirDrop(fileURL: URL) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            dbg("airdrop_service_unavailable")
            return
        }
        dbg("airdrop_start \(fileURL.lastPathComponent)")

        // Prefer a secondary screen so the share sheet appears away from VS Code
        let screens = NSScreen.screens
        let screen = screens.count > 1 ? screens[1] : (NSScreen.main ?? screens[0])
        dbg("anchor_screen: \(screen.frame) (of \(screens.count) screens)")
        let frame = screen.visibleFrame
        let winRect = NSRect(x: frame.midX - 1, y: frame.midY - 1, width: 2, height: 2)
        let win = NSPanel(
            contentRect: winRect,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.isFloatingPanel = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Do NOT order front — just hold a reference for the delegate.
        // Ordering it front blocks clicks intended for ShareSheetUI.
        anchorWindow = win

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        dbg("airdrop_activation_done")

        service.delegate = self
        service.perform(withItems: [fileURL])
        dbg("airdrop_perform_called")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.clickAirDropDevice()
        }

        // Return to accessory AFTER AirDrop auto-click completes (~10s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope scope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        dbg("airdrop_delegate_fired")
        return anchorWindow
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        dbg("airdrop_FAILED: \(error.localizedDescription) \((error as NSError).code)")
    }

    func sharingServiceDidStopSharing(_ sharingService: NSSharingService) {
        dbg("airdrop_did_stop_sharing")
    }

    private func clickAirDropDevice() {
        guard let deviceName = UserDefaults.standard.string(forKey: "airDropDeviceName"),
              !deviceName.isEmpty else {
            dbg("click_no_device_name")
            return
        }
        dbg("click_device: \(deviceName)")
        DispatchQueue.global().async {
            // On first attempt, dump full AX tree + running processes to diagnose
            self.dumpDiagnostics()
            for attempt in 0..<20 {
                if self.tryAXClick(deviceName: deviceName) { return }
                if self.tryCGClick(deviceName: deviceName) { return }
                if self.clickDeviceByOCR(deviceName: deviceName) { return }
                dbg("click_attempt_\(attempt + 1)_no_match")
                Thread.sleep(forTimeInterval: 0.5)
            }
            dbg("click_timeout_after_10s")
        }
    }

    private func dumpDiagnostics() {
        // Log all CGWindowList entries (no filter) to find ShareSheetUI
        let allWins = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in allWins {
            let owner = w["kCGWindowOwnerName"] as? String ?? ""
            let name  = w["kCGWindowName"] as? String ?? ""
            let pid   = w["kCGWindowOwnerPID"] as? Int32 ?? 0
            let layer = w["kCGWindowLayer"] as? Int ?? -1
            if owner.lowercased().contains("share") || owner.lowercased().contains("air") ||
               name.lowercased().contains("share") || name.lowercased().contains("airdrop") {
                dbg("cgwin: owner='\(owner)' name='\(name)' pid=\(pid) layer=\(layer)")
            }
        }
        // Log all running applications
        for app in NSWorkspace.shared.runningApplications {
            let name   = app.localizedName ?? "?"
            let bundle = app.bundleIdentifier ?? "?"
            let pid    = app.processIdentifier
            if name.lowercased().contains("share") || name.lowercased().contains("air") ||
               bundle.lowercased().contains("share") || bundle.lowercased().contains("air") {
                dbg("running: '\(name)' \(bundle) pid=\(pid)")
            }
        }
        // Dump AX tree of our own process's windows
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let ownApp = AXUIElementCreateApplication(ownPID)
        var wRef: AnyObject?
        if AXUIElementCopyAttributeValue(ownApp, kAXWindowsAttribute as CFString, &wRef) == .success,
           let wins = wRef as? [AXUIElement] {
            dbg("ax_own_wins: \(wins.count)")
            for w in wins { axDump(w) }
        }
    }

    private func axDump(_ elem: AXUIElement, depth: Int = 0) {
        guard depth <= 8 else { return }
        let indent = String(repeating: "  ", count: depth)
        var role: AnyObject?; var title: AnyObject?; var desc: AnyObject?; var val: AnyObject?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc)
        AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &val)
        let r = role as? String ?? "?"
        let t = title as? String ?? ""; let d = desc as? String ?? ""; let v = val as? String ?? ""
        dbg("\(indent)ax[\(depth)]: \(r) title='\(t)' desc='\(d)' val='\(v)'")
        var cRef: AnyObject?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
           let children = cRef as? [AXUIElement] {
            for c in children { axDump(c, depth: depth + 1) }
        }
    }

    private func tryAXClick(deviceName: String) -> Bool {
        // Collect all PIDs to search: own process first, then any share/airdrop-related process
        var pids: [pid_t] = [pid_t(ProcessInfo.processInfo.processIdentifier)]
        if let ext = shareSheetPID() { pids.append(ext) }
        // Also scan all running apps for share-related processes
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleIdentifier ?? "").lowercased()
            let pid = app.processIdentifier
            if !pids.contains(pid) &&
               (name.contains("share") || name.contains("air") || bundle.contains("share") || bundle.contains("air")) {
                dbg("ax_scan_app: '\(app.localizedName ?? "?")' pid=\(pid)")
                pids.append(pid)
            }
        }
        for pid in pids {
            let appElem = AXUIElementCreateApplication(pid)
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                dbg("ax_pid\(pid)_no_wins")
                continue
            }
            dbg("ax_pid\(pid)_wins:\(windows.count)")
            for win in windows {
                var titleRef: AnyObject?
                AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
                dbg("ax_pid\(pid)_win: title='\(titleRef as? String ?? "?")'")
                if axSearch(element: win, deviceName: deviceName) { return true }
            }
        }
        return false
    }

    @discardableResult
    private func axSearch(element: AXUIElement, deviceName: String) -> Bool {
        // Check label/title/description
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXLabelValueAttribute, kAXValueAttribute] {
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &val) == .success,
               let str = val as? String,
               str.localizedCaseInsensitiveContains(deviceName) || deviceName.localizedCaseInsensitiveContains(str),
               !str.isEmpty {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
                dbg("ax_clicked: \(str)")
                return true
            }
        }
        var childrenRef: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if axSearch(element: child, deviceName: deviceName) { return true }
            }
        }
        return false
    }

    private func clickDeviceByOCR(deviceName: String) -> Bool {
        // Scan ALL connected displays — share sheet may be on secondary screen
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        for displayID in displayIDs {
            guard let img = CGDisplayCreateImage(displayID) else { continue }
            let W = CGFloat(img.width)
            let H = CGFloat(img.height)
            let bounds = CGDisplayBounds(displayID)
            let scale = bounds.width > 0 ? W / bounds.width : 2.0

            var airDropBox: CGRect? = nil
            var deviceBox: CGRect? = nil
            var deviceText = ""

            // Save screenshot of this display for debugging
            let repDbg = NSBitmapImageRep(cgImage: img)
            if let png = repDbg.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/ocr_display\(displayID).png"))
            }

            let isMainDisplay = (displayID == CGMainDisplayID())
            let req = VNRecognizeTextRequest { r, _ in
                guard let obs = r.results as? [VNRecognizedTextObservation] else { return }
                let texts = obs.compactMap { $0.topCandidates(1).first?.string }
                dbg("ocr_display\(displayID)_texts: \(texts.joined(separator: " | "))")
                for o in obs {
                    guard let top = o.topCandidates(1).first, !top.string.isEmpty else { continue }
                    let s = top.string
                    if s.localizedCaseInsensitiveContains("AirDrop") { airDropBox = o.boundingBox }
                    if ocrMatches(s, deviceName) { deviceBox = o.boundingBox; deviceText = s }
                }
            }
            // Use accurate recognition on secondary display (device name may be small)
            req.recognitionLevel = isMainDisplay ? .fast : .accurate
            try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])

            guard let db = deviceBox else {
                dbg("ocr_display\(displayID): device '\(deviceName)' not found")
                continue
            }

            if isMainDisplay {
                // On main display: require "pchinnai2" to be near "AirDrop" header
                // (to avoid false matches from VS Code in background)
                guard let adb = airDropBox else {
                    dbg("ocr_display\(displayID): no AirDrop header on main display")
                    continue
                }
                let xDiff = abs(db.midX - adb.midX)
                let yBelow = adb.midY - db.midY
                dbg("ocr_main airdrop=(\(adb.midX),\(adb.midY)) device=(\(db.midX),\(db.midY)) xDiff=\(xDiff) yBelow=\(yBelow)")
                guard xDiff < 0.35 && yBelow > 0.02 && yBelow < 0.6 else {
                    dbg("ocr_main: '\(deviceText)' not near AirDrop header, skipping")
                    continue
                }
            } else {
                // Secondary display: ALSO require device to be near AirDrop header
                // (prevents false-positive clicks on background terminal/editor text)
                // Bug 2 (OCR misread "pchinnai2" as "pchinnal2") is resolved as a
                // side-effect — the misread terminal text won't pass this proximity check.
                guard let adb = airDropBox else {
                    dbg("ocr_display\(displayID): no AirDrop header on secondary display")
                    continue
                }
                let xDiff = abs(db.midX - adb.midX)
                let yBelow = adb.midY - db.midY
                dbg("ocr_secondary airdrop=(\(adb.midX),\(adb.midY)) device=(\(db.midX),\(db.midY)) xDiff=\(xDiff) yBelow=\(yBelow)")
                guard xDiff < 0.35 && yBelow > 0.02 && yBelow < 0.6 else {
                    dbg("ocr_secondary: '\(deviceText)' not near AirDrop header, skipping")
                    continue
                }
                dbg("ocr_secondary: found '\(deviceText)' at (\(db.midX),\(db.midY))")
            }

            // Convert to global Quartz screen coords
            let globalX = bounds.origin.x + db.midX * W / scale
            let globalY = bounds.origin.y + (1.0 - db.midY) * H / scale
            let iconY = globalY - 65  // also try the device icon above text label

            dbg("ocr_clicking '\(deviceText)' text=(\(globalX),\(globalY)) icon=(\(globalX),\(iconY))")

            let quartzX = globalX, quartzY = iconY  // MODIFIED to click icon instead of text

            // Enable pass-through on ALL autoSnip windows so no untitled panel
            // absorbs the click — only the external AirDrop.send window receives it
            let passthroughWins = DispatchQueue.main.sync { () -> [NSWindow] in
                let wins = NSApp.windows.filter { !$0.ignoresMouseEvents }
                wins.forEach { $0.ignoresMouseEvents = true }
                dbg("shell_passthrough_enabled count=\(wins.count) titles=\(wins.map { $0.title })")
                return wins
            }

            // Click at the OCR-located device position; routes to AirDrop.send window underneath
            cgClick(x: quartzX, y: quartzY)

            // Restore all windows after a brief moment
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.sync {
                passthroughWins.forEach { $0.ignoresMouseEvents = false }
                dbg("shell_passthrough_restored count=\(passthroughWins.count)")
            }
            return true
        }

        dbg("ocr_not_found_near_airdrop_on_any_display")
        return false
    }

    private func tryCGClick(deviceName: String) -> Bool {
        // Omit .optionOnScreenOnly so the share sheet is found on secondary/off-screen displays
        let opts: CGWindowListOption = [.excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return false }

        let myPID = Int32(ProcessInfo.processInfo.processIdentifier)
        for w in list {
            let owner = w["kCGWindowOwnerName"] as? String ?? ""
            guard owner.contains("ShareSheet") || owner.contains("AirDrop") else { continue }
            // Skip autoSnip's own shell NSPanel — target only the external AirDrop.send process
            guard let pid = w["kCGWindowOwnerPID"] as? Int32, pid != myPID else { continue }
            guard let bounds = w["kCGWindowBounds"] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 50 && height > 50 else { continue }

            let clickX = x + width / 2
            let clickY = y + height / 2
            dbg("cg_click owner=\(owner) at (\(clickX), \(clickY)) win=\(width)x\(height)")

            // Enable pass-through on ALL autoSnip windows so no untitled panel
            // absorbs the click — only the external AirDrop.send window receives it
            let passthroughWins = DispatchQueue.main.sync { () -> [NSWindow] in
                let wins = NSApp.windows.filter { !$0.ignoresMouseEvents }
                wins.forEach { $0.ignoresMouseEvents = true }
                dbg("cg_shell_passthrough_enabled count=\(wins.count)")
                return wins
            }
            cgClick(x: clickX, y: clickY)
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.sync {
                passthroughWins.forEach { $0.ignoresMouseEvents = false }
                dbg("cg_shell_passthrough_restored count=\(passthroughWins.count)")
            }
            return true
        }

        dbg("cg_no_sharesheet_window_found")
        return false
    }

    private func shareSheetPID() -> pid_t? {
        // Try NSWorkspace first
        for app in NSWorkspace.shared.runningApplications {
            let name = app.localizedName ?? ""
            if name.contains("ShareSheet") || name.contains("Share Sheet") {
                return app.processIdentifier
            }
        }
        // Fallback: search CGWindowList for owner name
        // Omit .optionOnScreenOnly so the share sheet PID is found on any display
        let opts: CGWindowListOption = [.excludeDesktopElements]
        if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
            for w in list {
                let owner = w["kCGWindowOwnerName"] as? String ?? ""
                if owner.contains("ShareSheet") || owner.contains("AirDrop") {
                    if let pid = w["kCGWindowOwnerPID"] as? Int32 { return pid }
                }
            }
        }
        return nil
    }

    private func cgClick(x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .combinedSessionState)

        // Warp cursor and send mouseMoved to trigger hover/focus state
        CGWarpMouseCursorPosition(point)
        Thread.sleep(forTimeInterval: 0.3)  // longer hover so ShareSheetUI can register hover
        let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)

        // Try both tap levels: HID (hardware-like) and session (window-server routed)
        for tapPoint: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
            let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up   = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,   mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: tapPoint)
            Thread.sleep(forTimeInterval: 0.15)
            up?.post(tap: tapPoint)
            Thread.sleep(forTimeInterval: 0.15)
            dbg("cgClick_tap=\(tapPoint == .cghidEventTap ? "HID" : "session") at (\(x),\(y))")
        }

        // Log what AX element is at this position and attempt kAXPressAction
        let sysElem = AXUIElementCreateSystemWide()
        var axElem: AXUIElement?
        if AXUIElementCopyElementAtPosition(sysElem, Float(x), Float(y), &axElem) == .success,
           let el = axElem {
            var roleRef: AnyObject?; var titleRef: AnyObject?; var pidRef: pid_t = 0
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            AXUIElementGetPid(el, &pidRef)
            let appName = NSRunningApplication(processIdentifier: pidRef)?.localizedName ?? "pid:\(pidRef)"
            dbg("ax_at_click: role=\(roleRef as? String ?? "?") title=\(titleRef as? String ?? "?") app=\(appName)")
            let pressResult = AXUIElementPerformAction(el, kAXPressAction as CFString)
            dbg("ax_press_result: \(pressResult.rawValue)")
        } else {
            dbg("ax_no_element_at (\(x),\(y))")
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
