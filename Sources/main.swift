import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = QuotaClient(), anchor = WindowAnchor()
    let ring = OverlayPanel(size: NSSize(width: 44, height: 57), shadow: false)
    let details = OverlayPanel(size: NSSize(width: 366, height: 244), shadow: true)
    let ringView = RingView(), detailsView = DetailsView()
    let prefs = UserDefaults.standard
    var menuItem: NSStatusItem!
    var settings: NSWindow?
    var statusLabel: NSTextField?
    var timer: Timer?, quotaTimer: Timer?, countdownTimer: Timer?
    var suppressed = false
    var mouseWasDown = false
    var lastFetch = Date.distantPast
    var lastVisible = false
    var paused = false
    var locating = false
    var error: String?
    private var diameterSetting: Double {
        let saved = prefs.double(forKey: "diameter")
        return min(44, max(28, saved == 0 ? 36 : saved))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1 else { NSApp.terminate(nil); return }
        prefs.set(diameterSetting, forKey: "diameter")
        ring.contentView = ringView; details.contentView = detailsView
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "额度环")
        let menu = NSMenu()
        for (name, action) in [("定位与设置…", #selector(showSettings)), ("立即刷新额度", #selector(refresh)), ("暂停／恢复显示", #selector(togglePause)), ("退出额度环", #selector(quit))] {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menuItem.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self, !NSRunningApplication.runningApplications(withBundleIdentifier: self.anchor.bundleID).isEmpty else { return }
            self.refresh()
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.details.isVisible else { return }; self.detailsView.needsDisplay = true
        }
        refresh()
        // Configuration opens first. AX requests happen only after the user's explicit button click.
        if !prefs.bool(forKey: "calibrated") || !AXIsProcessTrusted() { showSettings() }
    }

    @objc func refresh() {
        guard Date().timeIntervalSince(lastFetch) >= 30 else { return }
        lastFetch = Date()
        client.fetch { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.ringView.snapshot = snapshot; self.detailsView.snapshot = snapshot
                self.error = nil; self.ringView.failed = false
                self.statusLabel?.stringValue = "额度已连接：本周剩余 \(snapshot.ringText)，重置卡 \(snapshot.cardsText)。"
            case .failure(let error):
                self.error = error.localizedDescription; self.ringView.failed = true
                self.statusLabel?.stringValue = error.localizedDescription
            }
            self.detailsView.needsDisplay = true
        }
    }

    func tick() {
        // Do not read target bounds until the user has granted Accessibility and calibrated.
        guard !paused, !locating, prefs.bool(forKey: "calibrated"), let frame = anchor.frontWindowFrame() else {
            hide(); return
        }
        let diameter = CGFloat(diameterSetting)
        let center = Geometry.anchor(window: frame, x: CGFloat(prefs.double(forKey: "offsetX")), bottom: CGFloat(prefs.double(forKey: "offsetBottom")))
        let rect = Geometry.ringFrame(center: center, diameter: diameter)
        guard frame.contains(rect) else { hide(); return }
        let mouse = NSEvent.mouseLocation
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if down && !mouseWasDown && rect.insetBy(dx: -4, dy: -4).contains(mouse) { suppressed = true }
        mouseWasDown = down
        if suppressed && !rect.insetBy(dx: -20, dy: -20).contains(mouse) && !details.frame.contains(mouse) && !down { suppressed = false }
        if suppressed { hide(); return }
        let light = prefs.bool(forKey: "lightTheme")
        if ringView.light != light { ringView.light = light; detailsView.light = light; detailsView.needsDisplay = true }
        if ring.frame != rect { ring.setFrame(rect, display: true) }
        if !ring.isVisible { ring.orderFrontRegardless() }
        if !lastVisible, Date().timeIntervalSince(lastFetch) > 120 { refresh() }
        lastVisible = true
        let hovering = rect.contains(mouse) || (details.isVisible && details.frame.insetBy(dx: -12, dy: -8).contains(mouse))
        if hovering {
            let stale = detailsView.snapshot.map { Date().timeIntervalSince($0.fetchedAt) > 300 } ?? false
            let message = error.map { detailsView.snapshot == nil ? $0 : "\($0)；显示上次数据" } ?? (stale ? "数据已超过 5 分钟，等待刷新" : nil)
            if detailsView.error != message { detailsView.error = message; detailsView.needsDisplay = true }
            let size = detailsView.preferredSize
            let h = size.height, w = size.width
            let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })?.visibleFrame ?? frame
            var x = rect.maxX + 10
            if x + w > screen.maxX { x = rect.minX - w - 10 }
            x = min(max(x, screen.minX), screen.maxX - w)
            let y = min(max(center.y-h/2, screen.minY+8), screen.maxY-h-8)
            let detailFrame = NSRect(x: x, y: y, width: w, height: h)
            if details.frame != detailFrame { details.setFrame(detailFrame, display: true) }
            if !details.isVisible { detailsView.needsDisplay = true; details.orderFrontRegardless() }
        } else { details.orderOut(nil) }
    }
    func hide() {
        if ring.isVisible { ring.orderOut(nil) }
        if details.isVisible { details.orderOut(nil) }
        lastVisible = false
    }
    @objc func togglePause() { paused.toggle(); tick() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { client.stop() }

    @objc func showSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 395), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "额度环 · 首次定位与设置"; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 395)); window.contentView = content
        func label(_ text: String, x: CGFloat = 24, y: CGFloat, width: CGFloat = 470, height: CGFloat = 44, size: CGFloat = 13) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text); view.font = .systemFont(ofSize: size); view.frame = NSRect(x: x, y: y, width: width, height: height); content.addSubview(view); return view
        }
        _ = label("常驻数字 · 悬停查看详情", y: 335, height: 30, size: 20)
        _ = label("圆环中只显示数字。悬停显示重置时间、倒计时、重置卡数量和最近到期时间。点击会穿透到原控件。", y: 279, height: 46)
        let access = NSButton(title: "1. 授权窗口定位", target: self, action: #selector(requestAccessibility)); access.bezelStyle = .rounded; access.frame = NSRect(x: 24, y: 231, width: 170, height: 32); content.addSubview(access)
        _ = label("只读取 Codex 前台窗口的位置和尺寸。", x: 205, y: 236, width: 280, height: 25, size: 11)
        let locate = NSButton(title: "2. 定位原控件（5 秒）", target: self, action: #selector(calibrate)); locate.bezelStyle = .rounded; locate.frame = NSRect(x: 24, y: 184, width: 190, height: 32); content.addSubview(locate)
        _ = label("点击后切回 Codex，把鼠标停在原用量圆圈中心，等待 5 秒。", x: 225, y: 177, width: 265, height: 43, size: 11)
        _ = label("圆环大小", y: 135, width: 90, height: 24)
        let slider = NSSlider(value: diameterSetting, minValue: 28, maxValue: 44, target: self, action: #selector(sizeChanged(_:)))
        slider.frame = NSRect(x: 115, y: 132, width: 200, height: 26); slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = true; content.addSubview(slider)
        let theme = NSButton(checkboxWithTitle: "浅色背景", target: self, action: #selector(themeChanged(_:))); theme.state = prefs.bool(forKey: "lightTheme") ? .on : .off; theme.frame = NSRect(x: 350, y: 134, width: 130, height: 25); content.addSubview(theme)
        statusLabel = label("正在读取额度…", y: 72, height: 46, size: 12)
        _ = label("首次定位后跟随窗口左下角；界面缩放或导航布局改变时重新定位。时间均为北京时间。", y: 18, height: 42, size: 11)
        settings = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { statusLabel?.stringValue = "窗口定位已授权，可以进行第 2 步。" }
        else {
            statusLabel?.stringValue = "请在系统设置 → 隐私与安全性 → 辅助功能中启用“额度环”，再回来定位。"
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    @objc func calibrate() {
        guard AXIsProcessTrusted() else { statusLabel?.stringValue = "请先完成第 1 步的窗口定位授权。"; return }
        locating = true; hide(); settings?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self else { return }; self.locating = false
            guard let frame = self.anchor.frontWindowFrame() else {
                self.showSettings(); self.statusLabel?.stringValue = "未定位：请切回 Codex 主窗口并保持前台，再试一次。"; return
            }
            let point = NSEvent.mouseLocation
            guard frame.insetBy(dx: 12, dy: 30).contains(point), point.x-frame.minX < min(140, frame.width/3) else {
                self.showSettings(); self.statusLabel?.stringValue = "鼠标不在左侧导航区域，请重新定位。"; return
            }
            self.prefs.set(Double(point.x-frame.minX), forKey: "offsetX")
            self.prefs.set(Double(point.y-frame.minY), forKey: "offsetBottom")
            self.prefs.set(true, forKey: "calibrated")
            self.statusLabel?.stringValue = "已定位；可从菜单栏打开设置调整。"; self.tick()
        }
    }
    @objc func sizeChanged(_ sender: NSSlider) { prefs.set(min(44, max(28, sender.doubleValue)), forKey: "diameter"); tick() }
    @objc func themeChanged(_ sender: NSButton) { prefs.set(sender.state == .on, forKey: "lightTheme"); tick() }
}

if CommandLine.arguments.contains("--self-test") {
    runTests()
} else if CommandLine.arguments.contains("--check-data") {
    let client = QuotaClient(); var finished = false; var resultCode: Int32 = 0
    client.fetch { result in
        switch result {
        case .success(let s):
            let report: [String: Any] = ["remaining": s.ringText, "reset": s.resetAt.map(QuotaSnapshot.dateText) ?? "unknown", "cards": s.cardsText, "firstExpiry": s.expiryText, "expiryComplete": s.expiryComplete]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        case .failure(let e): print("ERROR: \(e.localizedDescription)"); resultCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    client.stop(); exit(resultCode)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
