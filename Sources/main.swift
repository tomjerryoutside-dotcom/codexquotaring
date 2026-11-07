import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    let client = QuotaClient(), anchor = WindowAnchor()
    let apiClient = APIBalanceClient()
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
    var syncingAPI = false
    var apiMenuItem: NSMenuItem?
    private var diameterSetting: Double {
        let saved = prefs.double(forKey: "diameter")
        return min(44, max(28, saved == 0 ? 36 : saved))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").count <= 1 else { NSApp.terminate(nil); return }
        prefs.set(diameterSetting, forKey: "diameter")
        ring.contentView = ringView; details.contentView = detailsView
        detailsView.apiBalance = APIBalanceSnapshot.load(from: prefs)
        menuItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menuItem.button?.image = NSImage(systemSymbolName: "circle.dotted.circle", accessibilityDescription: "额度环")
        let menu = NSMenu()
        for (name, action) in [("定位与设置…", #selector(showSettings)), ("立即刷新额度", #selector(refresh)), ("同步 API 余额", #selector(syncAPIBalance)), ("暂停／恢复显示", #selector(togglePause)), ("退出额度环", #selector(quit))] {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
            if action == #selector(syncAPIBalance) { apiMenuItem = item }
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
        if !prefs.bool(forKey: "calibrated") { showSettings() }
    }

    @objc func syncAPIBalance() {
        guard !syncingAPI else { return }
        syncingAPI = true; apiMenuItem?.title = "正在同步 API 余额…"
        detailsView.apiStatus = "正在同步 API 余额…"; detailsView.needsDisplay = true
        apiClient.sync { [weak self] result in
            guard let self else { return }
            self.syncingAPI = false; self.apiMenuItem?.title = "同步 API 余额"
            switch result {
            case .success(let snapshot):
                self.detailsView.apiBalance = snapshot; self.detailsView.apiStatus = nil
                self.statusLabel?.stringValue = "API 余额 \(snapshot.amountText)，核实于 \(snapshot.verifiedText)。"
            case .failure(let error):
                self.detailsView.apiStatus = self.detailsView.apiBalance == nil ? "API 同步失败，尚无核实值" : "API 同步失败，显示上次核实值"
                self.showSettings(); self.statusLabel?.stringValue = error.localizedDescription
            }
            self.detailsView.needsDisplay = true
        }
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
        guard !paused, !locating, prefs.bool(forKey: "calibrated"), let window = anchor.visibleWindow() else {
            hide(); return
        }
        let frame = window.frame
        let diameter = CGFloat(diameterSetting)
        let center = Geometry.anchor(window: frame, x: CGFloat(prefs.double(forKey: "offsetX")), bottom: CGFloat(prefs.double(forKey: "offsetBottom")))
        let rect = Geometry.ringFrame(center: center, diameter: diameter)
        guard frame.contains(rect) else { hide(); return }
        let mouse = NSEvent.mouseLocation
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let overRing = rect.insetBy(dx: -4, dy: -4).contains(mouse)
        let overDetails = details.isVisible && details.frame.insetBy(dx: -12, dy: -8).contains(mouse)
        let targetUnderMouse = (overRing || overDetails) && [window.number, ring.windowNumber, details.windowNumber]
            .contains(NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0))
        if down && !mouseWasDown && overRing && targetUnderMouse { suppressed = true }
        mouseWasDown = down
        if suppressed && !rect.insetBy(dx: -20, dy: -20).contains(mouse) && !details.frame.contains(mouse) && !down { suppressed = false }
        if suppressed { hide(); return }
        let light = prefs.bool(forKey: "lightTheme")
        if ringView.light != light { ringView.light = light; detailsView.light = light; detailsView.needsDisplay = true }
        if ring.frame != rect { ring.setFrame(rect, display: true) }
        // Stay immediately above Codex, beneath windows that cover Codex. Never activate it.
        ring.order(.above, relativeTo: window.number)
        if !lastVisible, Date().timeIntervalSince(lastFetch) > 120 { refresh() }
        lastVisible = true
        let hovering = (rect.contains(mouse) || overDetails) && targetUnderMouse
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
            if !details.isVisible { detailsView.needsDisplay = true }
            details.order(.above, relativeTo: ring.windowNumber)
        } else { details.orderOut(nil) }
    }
    func hide() {
        if ring.isVisible { ring.orderOut(nil) }
        if details.isVisible { details.orderOut(nil) }
        lastVisible = false
    }
    @objc func togglePause() { paused.toggle(); tick() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { client.stop(); apiClient.stop() }

    @objc func showSettings() {
        if let settings { settings.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 395), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "额度环 · 首次定位与设置"; window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 395)); window.contentView = content
        func label(_ text: String, x: CGFloat = 24, y: CGFloat, width: CGFloat = 470, height: CGFloat = 44, size: CGFloat = 13) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text); view.font = .systemFont(ofSize: size); view.frame = NSRect(x: x, y: y, width: width, height: height); content.addSubview(view); return view
        }
        _ = label("常驻数字 · 悬停查看详情", y: 335, height: 30, size: 20)
        _ = label("悬停显示重置时间、重置卡、剩余额度点及 API 余额。API 余额标注核实时间，从菜单栏按需同步。", y: 279, height: 46)
        _ = label("窗口跟随已就绪，无需辅助功能授权。", y: 236, height: 25, size: 12)
        let locate = NSButton(title: "定位原控件（5 秒）", target: self, action: #selector(calibrate)); locate.bezelStyle = .rounded; locate.frame = NSRect(x: 24, y: 184, width: 190, height: 32); content.addSubview(locate)
        _ = label("点击后切回 Codex，把鼠标停在原用量圆圈中心，等待 5 秒。", x: 225, y: 177, width: 265, height: 43, size: 11)
        _ = label("圆环大小", y: 135, width: 90, height: 24)
        let slider = NSSlider(value: diameterSetting, minValue: 28, maxValue: 44, target: self, action: #selector(sizeChanged(_:)))
        slider.frame = NSRect(x: 115, y: 132, width: 200, height: 26); slider.numberOfTickMarks = 5; slider.allowsTickMarkValuesOnly = true; content.addSubview(slider)
        let theme = NSButton(checkboxWithTitle: "浅色背景", target: self, action: #selector(themeChanged(_:))); theme.state = prefs.bool(forKey: "lightTheme") ? .on : .off; theme.frame = NSRect(x: 350, y: 134, width: 130, height: 25); content.addSubview(theme)
        statusLabel = label("正在读取额度…", y: 72, height: 46, size: 12)
        _ = label("首次定位后跟随窗口左下角；界面缩放或导航布局改变时重新定位。时间均为北京时间。", y: 18, height: 42, size: 11)
        settings = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func calibrate() {
        locating = true; hide(); settings?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak self] in
            guard let self else { return }; self.locating = false
            guard let window = self.anchor.visibleWindow(requireFrontmost: true) else {
                self.showSettings(); self.statusLabel?.stringValue = "未定位：请切回 Codex 主窗口并保持前台，再试一次。"; return
            }
            let frame = window.frame
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
} else if CommandLine.arguments.contains("--sync-api-balance") {
    let client = APIBalanceClient(); var finished = false; var resultCode: Int32 = 0
    client.sync { result in
        switch result {
        case .success(let snapshot):
            let report: [String: Any] = ["apiBalance": snapshot.amountText, "apiVerifiedAt": snapshot.verifiedText]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
        case .failure(let error): print("ERROR: \(error.localizedDescription)"); resultCode = 1
        }
        finished = true
    }
    while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    client.stop(); exit(resultCode)
} else if CommandLine.arguments.contains("--check-data") {
    let client = QuotaClient(); var finished = false; var resultCode: Int32 = 0
    client.fetch { result in
        switch result {
        case .success(let s):
            let api = APIBalanceSnapshot.load(from: .standard)
            let report: [String: Any] = ["remaining": s.ringText, "reset": s.resetAt.map(QuotaSnapshot.dateText) ?? "unknown", "cards": s.cardsText, "firstExpiry": s.expiryText, "expiryComplete": s.expiryComplete,
                                       "creditBalance": s.creditBalanceText, "apiBalance": api?.amountText ?? "尚未同步", "apiVerifiedAt": api?.verifiedText ?? "尚未同步"]
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
