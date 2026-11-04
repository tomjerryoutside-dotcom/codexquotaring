import AppKit
import ApplicationServices

enum Geometry {
    static func cocoaRect(axOrigin: CGPoint, size: CGSize, primaryTop: CGFloat) -> CGRect {
        CGRect(x: axOrigin.x, y: primaryTop - axOrigin.y - size.height, width: size.width, height: size.height)
    }
    static func anchor(window: CGRect, x: CGFloat, bottom: CGFloat) -> CGPoint {
        CGPoint(x: window.minX + x, y: window.minY + bottom)
    }
    static func ringFrame(center: CGPoint, diameter: CGFloat) -> CGRect {
        CGRect(x: center.x - (diameter+8)/2, y: center.y - diameter/2 - 4, width: diameter+8, height: diameter+21)
    }
}

/// Only the front window's bounds/minimized flag are read. No UI tree or chat contents.
final class WindowAnchor {
    let bundleID = "com.openai.codex"
    func frontWindowFrame() -> CGRect? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == bundleID else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(raw, to: AXUIElement.self)
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if (minimized as? Bool) == true { return nil }
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.width > 200, size.height > 200,
              let primary = NSScreen.screens.first else { return nil }
        return Geometry.cocoaRect(axOrigin: origin, size: size, primaryTop: primary.frame.maxY)
    }
}

struct Palette {
    let background: NSColor, surface: NSColor, text: NSColor, secondary: NSColor, track: NSColor
    static func make(light: Bool) -> Palette {
        light ? Palette(background: NSColor(white: 0.96, alpha: 1), surface: .white,
                        text: NSColor(white: 0.12, alpha: 1), secondary: NSColor(white: 0.43, alpha: 1), track: NSColor(white: 0.82, alpha: 1)) :
                Palette(background: NSColor(white: 0.135, alpha: 1), surface: NSColor(white: 0.15, alpha: 1),
                        text: NSColor(white: 0.95, alpha: 1), secondary: NSColor(white: 0.64, alpha: 1), track: NSColor(white: 0.38, alpha: 1))
    }
    static func accent(_ remaining: Double?, light: Bool = false) -> NSColor {
        guard let remaining else { return .secondaryLabelColor }
        if remaining <= 10 { return NSColor.systemRed }
        if remaining <= 20 { return NSColor.systemOrange }
        return light ? NSColor(red: 0.08, green: 0.52, blue: 0.40, alpha: 1) : NSColor(red: 0.37, green: 0.83, blue: 0.70, alpha: 1)
    }
}

func drawText(_ text: String, rect: NSRect, size: CGFloat, weight: NSFont.Weight = .regular,
              color: NSColor, align: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}

final class RingView: NSView {
    var snapshot: QuotaSnapshot? { didSet { needsDisplay = true } }
    var light = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.make(light: light)
        let diameter = bounds.width-8
        let center = NSPoint(x: bounds.midX, y: diameter/2+17)
        palette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let radius = diameter/2-2
        let full = NSBezierPath(ovalIn: NSRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
        full.lineWidth = 3; palette.track.setStroke(); full.stroke()
        if let remaining = snapshot?.remaining, remaining > 0 {
            let arc = NSBezierPath()
            // Flipped coordinates make increasing angles visually clockwise.
            arc.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: -90+360*remaining/100, clockwise: false)
            arc.lineWidth = 3; arc.lineCapStyle = .round
            (failed ? palette.secondary : Palette.accent(remaining, light: light)).setStroke(); arc.stroke()
        }
        let fontSize = diameter >= 40 ? CGFloat(17) : CGFloat(13)
        drawText(snapshot?.ringText ?? "—", rect: NSRect(x: 2, y: center.y-fontSize*0.62, width: bounds.width-4, height: fontSize+6), size: fontSize, weight: .semibold, color: palette.text, align: .center)
        drawText("本周", rect: NSRect(x: 0, y: 1, width: bounds.width, height: 13), size: 9, color: palette.secondary, align: .center)
    }
}

final class DetailsView: NSView {
    var snapshot: QuotaSnapshot?
    var light = false
    var error: String?
    override var isFlipped: Bool { true }
    private var rows: [(String, String)] {
        [("重置时间", snapshot?.resetAt.map { QuotaSnapshot.dateText($0) } ?? "暂不可用"),
         ("距离重置", snapshot?.countdown() ?? "暂不可用"),
         ("可用重置卡", snapshot?.cardsText ?? "暂不可用"),
         (snapshot?.expiryLabel ?? "最近到期", snapshot?.expiryText ?? "暂不可用")]
    }
    private func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)]).width)
    }
    private var remainingText: String { snapshot?.remaining == nil ? "暂不可用" : "剩余 \(snapshot!.ringText)%" }
    private var labelWidth: CGFloat { rows.map { width($0.0, size: 11) }.max() ?? 55 }
    var preferredSize: NSSize {
        let values = rows.map { width($0.1, size: 12, weight: .medium) }.max() ?? 120
        let header = width("Codex 周额度", size: 13, weight: .semibold) + width(remainingText, size: 10) + 20
        return NSSize(width: max(header, labelWidth + 12 + values) + 24, height: error == nil ? 144 : 178)
    }
    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.make(light: light)
        palette.surface.setFill()
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        panel.fill(); palette.secondary.withAlphaComponent(0.20).setStroke(); panel.lineWidth = 1; panel.stroke()
        drawText("Codex 周额度", rect: NSRect(x: 12, y: 11, width: 130, height: 20), size: 13, weight: .semibold, color: palette.text)
        let remainingWidth = width(remainingText, size: 10)
        drawText(remainingText, rect: NSRect(x: bounds.width-12-remainingWidth, y: 14, width: remainingWidth, height: 16), size: 10, color: palette.secondary, align: .right)
        let line = NSBezierPath(); line.move(to: NSPoint(x: 12, y: 36)); line.line(to: NSPoint(x: bounds.width-12, y: 36));
        palette.secondary.withAlphaComponent(0.25).setStroke(); line.lineWidth = 0.7; line.stroke()
        let valueX = 12 + labelWidth + 12
        for (index, pair) in rows.enumerated() {
            let y = CGFloat(44 + index*24)
            drawText(pair.0, rect: NSRect(x: 12, y: y+1, width: labelWidth, height: 17), size: 11, color: palette.secondary)
            drawText(pair.1, rect: NSRect(x: valueX, y: y, width: bounds.width-valueX-12, height: 18), size: 12, weight: .medium,
                     color: index == 1 ? Palette.accent(snapshot?.remaining, light: light) : palette.text)
        }
        if let error {
            drawText(error, rect: NSRect(x: 12, y: 143, width: bounds.width-24, height: 27), size: 10, color: palette.secondary)
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(size: NSSize, shadow: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = shadow; level = .floating
        ignoresMouseEvents = true; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }
}
