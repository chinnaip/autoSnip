// snip — one-shot screenshot → AirDrop sender
// Usage: snip [deviceName]  (defaults to UserDefaults airDropDeviceName)
// Captures display 1 silently, sends via AirDrop, exits when done.

import Cocoa
import Vision

// MARK: - Helpers

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
    guard ocr.count >= max(3, target.count - 3),
          abs(ocr.count - target.count) <= 2 else { return false }
    return levenshtein(ocr.lowercased(), target.lowercased()) <= 2
}

let logFile = "/tmp/snip_debug.txt"
func log(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8),
       let fh = FileHandle(forWritingAtPath: logFile) {
        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
    } else {
        try? line.write(toFile: logFile, atomically: false, encoding: .utf8)
    }
}

// MARK: - AppDelegate

final class SnipDelegate: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {

    var deviceName: String = ""
    var anchorWindow: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        // No Dock icon, no menu bar
        NSApp.setActivationPolicy(.accessory)

        // Device name: CLI arg > UserDefaults
        if CommandLine.arguments.count > 1 {
            deviceName = CommandLine.arguments[1]
        } else {
            deviceName = UserDefaults.standard.string(forKey: "airDropDeviceName") ?? ""
        }
        guard !deviceName.isEmpty else {
            log("snip_error: no device name — set via: defaults write com.yourname.autoSnip airDropDeviceName pchinnai2")
            exit(1)
        }
        log("snip_start device=\(deviceName)")

        // Capture display 1 (main display) silently
        let file = "/tmp/snip_\(Int(Date().timeIntervalSince1970)).png"
        let cap = Process()
        cap.launchPath = "/usr/sbin/screencapture"
        cap.arguments = ["-x", "-D", "1", file]
        cap.launch(); cap.waitUntilExit()
        log("snip_captured: \(file)")

        // AirDrop share sheet — anchor on secondary screen if available
        guard let svc = NSSharingService(named: .sendViaAirDrop) else {
            log("snip_error: AirDrop service unavailable"); exit(1)
        }
        let screens = NSScreen.screens
        let screen = screens.count > 1 ? screens[1] : (NSScreen.main ?? screens[0])
        let frame = screen.visibleFrame
        let win = NSPanel(
            contentRect: NSRect(x: frame.midX - 1, y: frame.midY - 1, width: 2, height: 2),
            styleMask: [.nonactivatingPanel], backing: .buffered, defer: false
        )
        win.isReleasedWhenClosed = false
        win.isFloatingPanel = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        anchorWindow = win

        NSApp.activate(ignoringOtherApps: true)
        svc.delegate = self
        svc.perform(withItems: [URL(fileURLWithPath: file)])
        log("snip_perform_called")

        // Auto-click device after share sheet loads
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            DispatchQueue.global().async { self.clickDevice() }
        }

        // Hard timeout — exit regardless after 30s
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            log("snip_timeout"); exit(0)
        }
    }

    func sharingService(_ s: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope scope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        anchorWindow
    }

    func sharingServiceDidStopSharing(_ s: NSSharingService) {
        log("snip_done"); exit(0)
    }

    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        log("snip_failed: \(error.localizedDescription)"); exit(1)
    }

    // MARK: - Click logic (same as autoSnip)

    private func clickDevice() {
        for attempt in 0..<20 {
            if tryAXClick()     { return }
            if clickByOCR()     { return }
            log("click_attempt_\(attempt + 1)_no_match")
            Thread.sleep(forTimeInterval: 0.5)
        }
        log("click_timeout")
    }

    private func tryAXClick() -> Bool {
        var pids: [pid_t] = [pid_t(ProcessInfo.processInfo.processIdentifier)]
        for app in NSWorkspace.shared.runningApplications {
            let n = (app.localizedName ?? "").lowercased()
            let b = (app.bundleIdentifier ?? "").lowercased()
            if !pids.contains(app.processIdentifier) &&
               (n.contains("share") || n.contains("air") || b.contains("share") || b.contains("air")) {
                pids.append(app.processIdentifier)
            }
        }
        for pid in pids {
            let appElem = AXUIElementCreateApplication(pid)
            var wRef: AnyObject?
            guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &wRef) == .success,
                  let wins = wRef as? [AXUIElement] else { continue }
            for win in wins {
                if axSearch(win) { return true }
            }
        }
        return false
    }

    private func axSearch(_ elem: AXUIElement) -> Bool {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXLabelValueAttribute, kAXValueAttribute] {
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(elem, attr as CFString, &val) == .success,
               let str = val as? String, !str.isEmpty,
               str.localizedCaseInsensitiveContains(deviceName) || deviceName.localizedCaseInsensitiveContains(str) {
                AXUIElementPerformAction(elem, kAXPressAction as CFString)
                log("ax_clicked: \(str)")
                return true
            }
        }
        var cRef: AnyObject?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &cRef) == .success,
           let children = cRef as? [AXUIElement] {
            for child in children { if axSearch(child) { return true } }
        }
        return false
    }

    private func clickByOCR() -> Bool {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)

        for displayID in displayIDs {
            guard let img = CGDisplayCreateImage(displayID) else { continue }
            let bounds = CGDisplayBounds(displayID)
            let W = CGFloat(img.width)

            var airDropBox: CGRect? = nil
            var deviceBox: CGRect? = nil
            var deviceText = ""

            let isMain = (displayID == CGMainDisplayID())
            let req = VNRecognizeTextRequest { r, _ in
                guard let obs = r.results as? [VNRecognizedTextObservation] else { return }
                for o in obs {
                    guard let top = o.topCandidates(1).first, !top.string.isEmpty else { continue }
                    let s = top.string
                    if s.localizedCaseInsensitiveContains("AirDrop") { airDropBox = o.boundingBox }
                    if self.ocrMatches(s, self.deviceName) { deviceBox = o.boundingBox; deviceText = s }
                }
            }
            req.recognitionLevel = isMain ? .fast : .accurate
            try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])

            guard let db = deviceBox else { continue }

            // Require device label to be near AirDrop header (false-positive guard)
            guard let adb = airDropBox else {
                log("ocr_display\(displayID): no AirDrop header, skipping")
                continue
            }
            let xDiff = abs(db.midX - adb.midX)
            let yBelow = adb.midY - db.midY
            guard xDiff < 0.35 && yBelow > 0.02 && yBelow < 0.6 else {
                log("ocr_display\(displayID): '\(deviceText)' not near AirDrop header")
                continue
            }

            // NSScreen-based coordinate conversion (CGDisplayBounds can mismatch Quartz space)
            guard let screen = NSScreen.screens.first(where: {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
            }) else { continue }
            let sf = screen.frame
            let mainH = NSScreen.screens[0].frame.maxY
            let qOriginY = mainH - sf.origin.y - sf.height
            let globalX = sf.origin.x + db.midX * sf.width
            let globalY = qOriginY + (1.0 - db.midY) * sf.height
            let quartzY = globalY - 30

            log("ocr_clicking '\(deviceText)' at (\(globalX),\(quartzY))")

            // Pass-through all our windows so the click reaches AirDrop.send
            let passWins = DispatchQueue.main.sync { () -> [NSWindow] in
                let wins = NSApp.windows.filter { !$0.ignoresMouseEvents }
                wins.forEach { $0.ignoresMouseEvents = true }
                return wins
            }
            cgClick(x: globalX, y: quartzY)
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.sync { passWins.forEach { $0.ignoresMouseEvents = false } }
            return true
        }
        return false
    }

    // Retain local copy of ocrMatches (can't cross-file in same module)
    private func ocrMatches(_ a: String, _ b: String) -> Bool {
        guard a.count >= max(3, b.count - 3), abs(a.count - b.count) <= 2 else { return false }
        return levenshtein(a.lowercased(), b.lowercased()) <= 2
    }

    private func cgClick(x: CGFloat, y: CGFloat) {
        let pt = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(pt)
        Thread.sleep(forTimeInterval: 0.3)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.3)
        for tap: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: tap)
            Thread.sleep(forTimeInterval: 0.15)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: tap)
            Thread.sleep(forTimeInterval: 0.15)
        }
        let sysElem = AXUIElementCreateSystemWide()
        var axElem: AXUIElement?
        if AXUIElementCopyElementAtPosition(sysElem, Float(x), Float(y), &axElem) == .success, let el = axElem {
            AXUIElementPerformAction(el, kAXPressAction as CFString)
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = SnipDelegate()
app.delegate = delegate
app.run()
