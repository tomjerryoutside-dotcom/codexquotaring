import Foundation
import CoreGraphics
import AppKit

func runTests() {
    var count = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        count += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    let now = Date(timeIntervalSince1970: 1793792924)
    let fixture: [String: Any] = [
        "rateLimitsByLimitId": ["codex": ["primary": ["usedPercent": 66, "windowDurationMins": 10080, "resetsAt": 1794167539]]],
        "rateLimitResetCredits": ["availableCount": 2, "credits": [
            ["id": "b", "status": "available", "expiresAt": 1796165124],
            ["id": "old", "status": "consumed", "expiresAt": 1790000000],
            ["id": "a", "status": "available", "expiresAt": 1796069788]
        ]]
    ]
    let actual = QuotaSnapshot.parse(fixture, now: now)
    expect(actual.ringText == "34", "numeric ring without percent suffix")
    expect(actual.cards == 2, "authoritative card count")
    expect(actual.expiryText == "2026/12/01 04:16", "earliest available expiry, ignoring consumed cards")
    expect(actual.expiryComplete, "all available cards have known expiry")
    expect(actual.resetAt.map(QuotaSnapshot.dateText) == "2026/11/09 03:52", "reset displayed in Beijing timezone")
    expect(actual.countdown(now: now) == "4天 8小时 3分钟", "countdown relative to supplied clock")
    expect(actual.countdown(now: now.addingTimeInterval(60)) == "4天 8小时 2分钟", "countdown advances without another quota request")
    expect(actual.countdown(now: Date(timeIntervalSince1970: 1794167530)) == "不足 1 分钟", "nonzero subminute remainder")
    expect(actual.countdown(now: Date(timeIntervalSince1970: 1794167540)) == "等待额度刷新", "reset crossing does not fabricate restored allowance")
    let empty = QuotaSnapshot.parse([:])
    expect(empty.ringText == "—" && empty.cardsText == "暂不可用", "missing values are unknown, not zero")
    let secondary = QuotaSnapshot.parse(["rateLimits": ["primary": ["usedPercent": 50, "windowDurationMins": 300], "secondary": ["usedPercent": 80, "windowDurationMins": 10080]]])
    expect(secondary.ringText == "20", "weekly window can be secondary")
    let notWeekly = QuotaSnapshot.parse(["rateLimits": ["primary": ["usedPercent": 50, "windowDurationMins": 300]]])
    expect(notWeekly.remaining == nil, "5-hour window must not masquerade as week")
    let partial = QuotaSnapshot.parse(["rateLimitResetCredits": ["availableCount": 4, "credits": [["status": "available", "expiresAt": 1796069788]]]])
    expect(partial.cards == 4 && !partial.expiryComplete && partial.expiryLabel == "最近到期（已知）", "partial details don't override total or claim global nearest expiry")
    let noCards = QuotaSnapshot.parse(["rateLimitResetCredits": ["availableCount": 0, "credits": []]])
    expect(noCards.expiryText == "无可用卡", "zero cards distinct from unavailable data")
    let missingExpiry = QuotaSnapshot.parse(["rateLimitResetCredits": ["availableCount": 2, "credits": NSNull()]])
    expect(missingExpiry.expiryText == "暂不可用", "unknown expiry is not unlimited validity")
    expect(QuotaSnapshot.number(true) == nil, "booleans must not decode as a percentage")
    let clamped = QuotaSnapshot.parse(["rateLimits": ["primary": ["usedPercent": 120, "windowDurationMins": 10080]]])
    expect(clamped.ringText == "0", "out-of-range usage stays within ring bounds")
    let other = QuotaSnapshot.parse(["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 1, "windowDurationMins": 10080]]]])
    expect(other.remaining == nil, "another bucket must not be selected by arbitrary order")
    let frame = Geometry.cocoaRect(axOrigin: CGPoint(x: -1200, y: 100), size: CGSize(width: 900, height: 600), primaryTop: 1080)
    expect(frame == CGRect(x: -1200, y: 380, width: 900, height: 600), "AX-to-Cocoa coordinate conversion on a left monitor")
    let center = Geometry.anchor(window: frame, x: 32, bottom: 108)
    expect(center == CGPoint(x: -1168, y: 488), "anchor measured from window bottom-left")
    let moved = frame.offsetBy(dx: 200, dy: 75)
    expect(Geometry.anchor(window: moved, x: 32, bottom: 108) == CGPoint(x: center.x+200, y: center.y+75), "anchor follows translation")
    let resized = CGRect(x: frame.minX, y: frame.minY-100, width: 1100, height: 700)
    expect(Geometry.anchor(window: resized, x: 32, bottom: 108).y == center.y-100, "anchor follows bottom edge during resize")
    func window(_ number: Int, pid: Int32 = 42, onscreen: Bool = true, layer: Int = 0,
                alpha: Double = 1, width: CGFloat = 900, height: CGFloat = 600) -> [String: Any] {
        [kCGWindowNumber as String: number, kCGWindowOwnerPID as String: pid,
         kCGWindowIsOnscreen as String: onscreen, kCGWindowLayer as String: layer,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(x: -1200, y: 100, width: width, height: height).dictionaryRepresentation]
    }
    func select(_ windows: [[String: Any]]) -> AnchoredWindow? {
        WindowAnchor.selectWindow(windows, ownerPIDs: [42], primaryTop: 1080)
    }
    let background = select([window(10, pid: 99), window(20)])
    expect(background?.number == 20 && background?.frame == frame, "visible Codex remains anchored behind an active browser")
    expect(select([window(20, onscreen: false)]) == nil, "minimized or off-space window is excluded")
    expect(select([window(20, alpha: 0)]) == nil, "transparent window is excluded")
    expect(select([window(20, layer: 3)]) == nil, "floating utility window is not a main window")
    expect(select([window(20, width: 100)]) == nil, "small auxiliary window is excluded")
    expect(select([window(20, pid: 99)]) == nil, "another app cannot become the anchor")
    expect(WindowAnchor.selectWindow([window(20)], ownerPIDs: [], primaryTop: 1080) == nil, "hidden or exited Codex has no anchor")
    expect(select([window(30), window(20)])?.number == 30, "initial selection breaks an area tie by window order")
    expect(select([[:], window(0), window(20)])?.number == 20, "invalid metadata is skipped without selecting an invalid window ID")
    let tracking = WindowAnchor()
    let main = window(20, width: 720, height: 1250)
    let observerSurfaces = [window(30, width: 373, height: 532), window(31, width: 373, height: 532)]
    func follow(_ visible: [[String: Any]], all: [[String: Any]]? = nil) -> AnchoredWindow? {
        tracking.resolveWindow(visible, ownerPIDs: [42], primaryTop: 1080) { all ?? visible }
    }
    expect(follow(observerSurfaces + [main])?.number == 20, "starting with the observer open binds to the Codex main window")
    let largerHelper = window(40, width: 1000, height: 900)
    let smallerMain = window(20, width: 620, height: 840)
    expect(follow([largerHelper, smallerMain])?.frame.size == CGSize(width: 620, height: 840), "a frontmost helper does not steal the anchor after the main window resizes")
    expect(follow(observerSurfaces, all: observerSurfaces + [window(20, onscreen: false, width: 720, height: 1250)]) == nil,
           "hide rather than move to the observer when the bound window leaves the current desktop")
    expect(follow(observerSurfaces + [main])?.number == 20, "returning to the desktop restores the same anchor")
    expect(follow(observerSurfaces + [window(50)])?.number == 50, "closing the main window allows binding a replacement")
    func points(_ balance: Any?, unlimited: Bool = false) -> QuotaSnapshot {
        QuotaSnapshot.parse(["rateLimitsByLimitId": ["codex": ["credits": ["balance": balance ?? NSNull(), "unlimited": unlimited]]]])
    }
    expect(points("62500.0000000000").creditBalanceText == "62,500 点", "credit balance uses the authoritative decimal string, not weekly percentage")
    expect(points("0").creditBalanceText == "0 点", "an actual zero balance is displayed as zero")
    expect(points(nil).creditBalanceText == "暂不可用", "missing point balance is not zero")
    expect(points(nil, unlimited: true).creditBalanceText == "不限量", "unlimited credits remain distinct from an unknown numeric balance")
    expect(points("1234.5678").creditBalanceText == "1,234.56 点", "fractional points are not rounded up")
    expect(points("0.001").creditBalanceText == "<0.01 点", "small positive credit balance is not shown as zero")
    expect(points(true).creditBalanceText == "暂不可用", "boolean is not a point balance")
    expect(["-1", "NaN", "Infinity", "12usd", "1,000", ""].allSatisfy { BalanceFormat.decimal($0) == nil }, "invalid decimal strings are rejected in full")
    let apiJSON: [String: Any] = ["amount": "12.34", "currency": "USD", "verifiedAt": now.timeIntervalSince1970]
    let api = APIBalanceSnapshot.parse(apiJSON, now: now)!
    expect(api.amountText == "US$12.34", "API dollars are explicitly separate from Codex points")
    expect(api.verifiedAt == now, "API timestamp records the actual check, not time of rendering")
    expect(APIBalanceSnapshot.parse(["amount": "0", "currency": "USD", "verifiedAt": now.timeIntervalSince1970], now: now)?.amountText == "US$0.00", "verified zero API balance remains valid")
    expect(APIBalanceSnapshot.parse(["amount": "-12.34", "currency": "USD", "verifiedAt": now.timeIntervalSince1970], now: now)?.amountText == "-US$12.34", "negative API balance is preserved rather than clamped or discarded")
    expect(APIBalanceSnapshot.parse(["amount": "12.34", "currency": "CNY", "verifiedAt": now.timeIntervalSince1970], now: now) == nil, "unsupported currency is not relabeled as dollars")
    expect(APIBalanceSnapshot.parse(["amount": "12.34", "currency": "USD"], now: now) == nil, "API balance without a verification time is unavailable")
    expect(APIBalanceSnapshot.parse(["amount": "12.34", "currency": "USD", "verifiedAt": now.addingTimeInterval(120).timeIntervalSince1970], now: now) == nil, "future-dated API balance is rejected")
    expect(APIBalanceClient.message("arbitrary browser output", prefix: "QUOTARING_API_RESULT ") == nil, "unstructured browser output cannot become a balance")
    if let path = ProcessInfo.processInfo.environment["QUOTARING_PREVIEW_PATH"] {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let view = DetailsView()
        var previewFixture = fixture
        previewFixture["rateLimitsByLimitId"] = ["codex": ["primary": ["usedPercent": 66, "windowDurationMins": 10080, "resetsAt": 1794167539], "credits": ["balance": "62500.0000000000", "unlimited": false]]]
        view.snapshot = QuotaSnapshot.parse(previewFixture, now: now)
        view.apiBalance = api; view.light = true
        view.frame = NSRect(origin: .zero, size: view.preferredSize)
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
    }
    print("PASS: \(count) model, balance, geometry and window-selection checks")
}
