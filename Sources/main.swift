import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid
import ObjectiveC.runtime
import UniformTypeIdentifiers

private let benqVendorID = 0x04A5
private let iScreenBarProductID = 0x2501
private let appleDisplayVendorID: UInt32 = 0x0610
/// Studio Display 不同批次的型号编号不同；未收录的型号再按屏幕名称识别。
private let studioDisplayProductIDs: Set<UInt32> = [0xAE46, 0xAE3A]
private let pollInterval: TimeInterval = 0.25

private func log(_ message: String) {
    let formatter = ISO8601DateFormatter()
    print("[\(formatter.string(from: Date()))] \(message)")
    fflush(stdout)
}

private let activeControlColor = NSColor.controlAccentColor

private enum UIStyle {
    static let panelWidth: CGFloat = 300
    static let contentWidth: CGFloat = 268
    static let outerInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 8
    static let bodyFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let controlFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let iconSize: CGFloat = 15
    static let controlHeight: CGFloat = 46
    static let controlRadius: CGFloat = 12
    static let chipOffColor = adaptiveColor(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.14))
}

/// 界面文字以英文为键，从 Localizable.strings 读取当前系统语言的翻译（如 zh-Hans）。
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private func adaptiveColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
}

/// 将模板图像按指定颜色着色，绘制时才解析颜色，可随外观变化。
private func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

/// 胶囊滑块：亮度为白色填充，色温为暖到冷渐变加细长标记，均无圆形滑钮。
private final class InteractiveSlider: NSSlider {
    enum Track {
        case brightness
        case temperature
    }

    private let track: Track

    init(value: Double, minValue: Double, maxValue: Double, track: Track) {
        self.track = track
        super.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }

    override var doubleValue: Double {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    private var fraction: CGFloat {
        guard maxValue > minValue else { return 0 }
        return CGFloat((doubleValue - minValue) / (maxValue - minValue))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = bounds
        let radius = bar.height / 2
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.45)
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
        switch track {
        case .brightness:
            // 与控制中心的显示器亮度一致：浅灰轨道，左侧白色填充，内嵌太阳图标，无滑钮。
            UIStyle.chipOffColor.setFill()
            bar.fill()
            let fillWidth = max(bar.height, bar.width * fraction)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: fillWidth, height: bar.height),
                         xRadius: radius, yRadius: radius).fill()
            if let icon = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) {
                let iconRect = NSRect(x: bar.minX + 9, y: bar.midY - icon.size.height / 2,
                                      width: icon.size.width, height: icon.size.height)
                tintedImage(icon, color: NSColor(white: 0.45, alpha: 1)).draw(in: iconRect)
            }
        case .temperature:
            // 暖到冷渐变，当前位置用细长白色标记表示。
            let colors = [
                NSColor(srgbRed: 1, green: 0.62, blue: 0.25, alpha: 1),
                NSColor(srgbRed: 1, green: 0.91, blue: 0.78, alpha: 1),
                NSColor(srgbRed: 0.85, green: 0.91, blue: 1, alpha: 1),
                NSColor(srgbRed: 0.61, green: 0.76, blue: 1, alpha: 1)
            ]
            NSGradient(colors: colors, atLocations: [0, 0.48, 0.72, 1], colorSpace: .sRGB)?.draw(in: bar, angle: 0)
            let markerWidth: CGFloat = 5
            let marker = NSRect(x: bar.minX + 8 + fraction * (bar.width - markerWidth - 16), y: bar.minY + 6,
                                width: markerWidth, height: bar.height - 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: marker, xRadius: markerWidth / 2, yRadius: markerWidth / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let outline = NSBezierPath(roundedRect: bar.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        outline.lineWidth = 0.5
        NSColor.black.withAlphaComponent(0.08).setStroke()
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 拖动期间为 true，状态刷新不应覆盖用户正在拖动的值。
    private(set) var isTracking = false

    // 自行跟踪拖动，使整条胶囊都可点按；isContinuous 时拖动中也发送 action，松开时总会发送。
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isTracking = true
        func update(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // 色温标记绘制时左右各内缩 8 pt 并以标记中心定位，命中区域与之一致。
            let inset: CGFloat = track == .temperature ? 10.5 : 0
            let position = min(max((point.x - inset) / max(bounds.width - inset * 2, 1), 0), 1)
            doubleValue = minValue + Double(position) * (maxValue - minValue)
            if isContinuous { sendAction(action, to: target) }
        }
        update(with: event)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            update(with: next)
            if next.type == .leftMouseUp { break }
        }
        // 先结束跟踪再发送最终 action，接收方可据此区分拖动中与松开。
        isTracking = false
        sendAction(action, to: target)
    }
}

/// 菜单栏图标：空心圆环常亮，周围 8 条光芒从正上方顺时针按亮度依次点亮。
/// 同步异常时在右下角加一个小圆点提示。
private func brightnessStatusIcon(level: Int, warning: Bool) -> NSImage {
    let litDots = Int((Double(min(max(level, 0), 100)) / 100 * 8).rounded(.up))
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 3.6, y: center.y - 3.6, width: 7.2, height: 7.2))
        ring.lineWidth = 1.5
        NSColor.black.setStroke()
        ring.stroke()
        for index in 0..<8 {
            let angle = CGFloat.pi / 2 - CGFloat(index) * .pi / 4
            let ray = NSBezierPath()
            ray.move(to: NSPoint(x: center.x + 6.2 * cos(angle), y: center.y + 6.2 * sin(angle)))
            ray.line(to: NSPoint(x: center.x + 7.3 * cos(angle), y: center.y + 7.3 * sin(angle)))
            ray.lineWidth = 1.6
            ray.lineCapStyle = .round
            NSColor.black.withAlphaComponent(index < litDots ? 1 : 0.25).setStroke()
            ray.stroke()
        }
        if warning {
            let badge = NSRect(x: rect.maxX - 6.5, y: rect.minY + 0.5, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = String(format: L("iScreenBar brightness %d%%"), level) + (warning ? L(", sync error") : "")
    return image
}

/// 控制中心样式的开关：圆形按钮，或带圆形图标、标题与说明的卡片。
private final class FeatureButton: NSButton {
    enum Style {
        case circle
        case tile
    }

    var style: Style = .tile {
        didSet { needsDisplay = true }
    }
    /// 开启时显示在标题下方的简短说明；关闭时只显示标题。
    var detail: String? {
        didSet { if detail != oldValue { needsDisplay = true } }
    }
    private let accentColor: NSColor

    init(title: String, symbol: String, accentColor: NSColor) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        setButtonType(.toggle)
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // 按钮自身绘制，不让符号图像的对齐边距影响布局位置。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    override var title: String {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let isOn = state == .on
        let foreground: NSColor = isOn ? .white : .labelColor
        switch style {
        case .circle:
            fill(NSBezierPath(ovalIn: bounds), isOn: isOn)
            drawIcon(centeredAt: NSPoint(x: bounds.midX, y: bounds.midY),
                     pointSize: (bounds.height * 0.4).rounded(), color: foreground)
        case .tile:
            let chip = NSRect(x: 9, y: (bounds.height - 28) / 2, width: 28, height: 28)
            fill(NSBezierPath(ovalIn: chip), isOn: isOn)
            drawIcon(centeredAt: NSPoint(x: chip.midX, y: chip.midY), pointSize: 13, color: foreground)
            let textX = chip.maxX + 8
            let textWidth = bounds.width - textX - 6
            let note = isOn ? detail : nil
            let titleY = note == nil ? (bounds.height - 15) / 2 : (bounds.height - 29) / 2
            // 标题过长时逐级缩小字号（最小 10.5 pt），避免英文等较长文字被截断。
            let titleFont = [12, 11.5, 11, 10.5].lazy
                .map { NSFont.systemFont(ofSize: $0, weight: .semibold) }
                .first { (self.title as NSString).size(withAttributes: [.font: $0]).width <= textWidth }
                ?? .systemFont(ofSize: 10.5, weight: .semibold)
            drawText(title, in: NSRect(x: textX, y: titleY, width: textWidth, height: 15),
                     font: titleFont, color: .labelColor)
            if let note {
                drawText(note, in: NSRect(x: textX, y: titleY + 15, width: textWidth, height: 14),
                         font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fill(_ shape: NSBezierPath, isOn: Bool) {
        (isOn ? accentColor : UIStyle.chipOffColor).setFill()
        shape.fill()
        if isHighlighted {
            NSColor.black.withAlphaComponent(0.12).setFill()
            shape.fill()
        }
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func drawIcon(centeredAt center: NSPoint, pointSize: CGFloat, color: NSColor) {
        guard let image else { return }
        let icon = image.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) ?? image
        let iconRect = NSRect(x: center.x - icon.size.width / 2, y: center.y - icon.size.height / 2,
                              width: icon.size.width, height: icon.size.height)
        tintedImage(icon, color: color)
            .draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// 圆角磨砂背景：模糊窗口后方内容，用作开关卡片的底。
private final class FrostedBackground: NSVisualEffectView {
    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        let side = cornerRadius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        mask.resizingMode = .stretch
        maskImage = mask
    }

    required init?(coder: NSCoder) { nil }
}

/// 标题旁的连接状态圆点。
private final class StatusDot: NSView {
    var color: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// 保留 macOS 开关的尺寸与滑块形态，只固定开启态的高亮颜色。
private final class AccentSwitch: NSButton {
    private let accentColor: NSColor
    private let knobLayer = CALayer()

    init(accentColor: NSColor = .systemBlue) {
        self.accentColor = accentColor
        super.init(frame: .zero)
        title = ""
        setButtonType(.toggle)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOpacity = 0.18
        knobLayer.shadowRadius = 1.5
        knobLayer.shadowOffset = NSSize(width: 0, height: -0.5)
        layer?.addSublayer(knobLayer)
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }

    override var state: NSControl.StateValue {
        didSet { updateAppearance(animated: window != nil) }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance(animated: false) }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        guard let layer else { return }
        let knobSize = max(0, bounds.height - 4)
        let knobX = state == .on ? max(2, bounds.width - knobSize - 2) : 2
        let changes = {
            layer.backgroundColor = (self.state == .on
                ? self.accentColor
                : NSColor.systemGray.withAlphaComponent(0.34)).cgColor
            layer.opacity = self.isEnabled ? 1 : 0.45
            self.knobLayer.cornerRadius = knobSize / 2
            self.knobLayer.frame = NSRect(x: knobX, y: 2, width: knobSize, height: knobSize)
        }
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.16)
            changes()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}

private struct SavedMode: Codable {
    let name: String
    let brightness: Int
    let temperature: Int
    let videoMode: Bool
}

private final class StatusIndicator: NSObject, NSMenuDelegate {
    private let presenceDelayOptions = [180, 300, 600]
    private let item: NSStatusItem
    private let lamp: LampController
    private let statusMenu = NSMenu()
    /// 开灯后等待固件就绪期间，同类调整只保留最新一次。
    private var pendingLampOnActions: [(key: String, action: () -> Void)] = []
    private var isWaitingForLampOn = false
    private weak var ambientStatusItem: NSMenuItem?
    private var iconKey: String?
    private var isMenuOpen = false
    private let panelMenuItem = NSMenuItem()
    private let powerSwitch: FeatureButton = {
        let button = FeatureButton(title: "", symbol: "power", accentColor: activeControlColor)
        button.style = .circle
        button.setAccessibilityLabel(L("Light power"))
        return button
    }()
    private let statusDot = StatusDot()
    private let connectionLabel = NSTextField(labelWithString: L("Not connected"))
    private let brightnessSlider = InteractiveSlider(value: 50, minValue: 1, maxValue: 100, track: .brightness)
    private let temperatureSlider = InteractiveSlider(value: 5000, minValue: 2700, maxValue: 6500, track: .temperature)
    private let timeTemperatureSwitch = FeatureButton(title: L("Auto Color"), symbol: "circle.lefthalf.filled", accentColor: activeControlColor)
    private let autoLightSwitch = FeatureButton(title: L("Auto Light"), symbol: "sun.max", accentColor: activeControlColor)
    private let presenceSwitch = FeatureButton(title: L("Presence"), symbol: "figure.seated.side", accentColor: activeControlColor)
    private let presenceDelayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let presenceSensitivityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var presenceDelaySeconds = 180
    private var presenceSensitivity = 2
    private let videoModeSwitch = FeatureButton(title: L("Video Mode"), symbol: "video", accentColor: activeControlColor)
    private let modeButton = NSButton(title: L("My Favorite"), target: nil, action: nil)
    private var modeCenterWindow: NSWindow?
    private let brightnessFollowSwitch = FeatureButton(title: L("Follow Display"), symbol: "display", accentColor: activeControlColor)
    private let powerSyncSwitch = FeatureButton(title: L("Sleep Sync"), symbol: "moon.zzz", accentColor: activeControlColor)
    private let captureBrightButton = FeatureButton(title: L("Bright: Off"), symbol: "sun.max.fill", accentColor: .systemOrange)
    private let captureDarkButton = FeatureButton(title: L("Dim: On"), symbol: "moon.fill", accentColor: .systemBlue)
    private let ambientEnableSwitch = AccentSwitch()
    private let brightThresholdLabel = NSTextField(labelWithString: "--")
    private let darkThresholdLabel = NSTextField(labelWithString: "--")
    private let ambientStatusLabel = NSTextField(labelWithString: L("Ambient light not calibrated"))
    private(set) var isBrightnessFollowEnabled: Bool
    private(set) var isPowerSyncEnabled: Bool
    private(set) var isTimeTemperatureEnabled: Bool
    private(set) var ambientCloseThreshold: Int?
    private(set) var ambientOpenThreshold: Int?
    private(set) var currentDisplayAmbientProxy: Int?
    private var currentAmbientSourceName = "显示器"
    private var ambientThresholdSource: String?
    private var areAmbientRulesEnabled: Bool
    private var isHealthy = true
    private var isAsleep: Bool
    private var autoLightChangePendingUntil: Date?
    private var pendingAutoLightState: Bool?
    private var lastScheduledTemperature: Int?
    private var lastScheduledTemperatureChangeAt = Date.distantPast
    private var lastDragTemperatureSentAt = Date.distantPast
    private var lastDragBrightnessSentAt = Date.distantPast
    private var lastFrontmostBundleID: String?
    private var isAmbientPresenceLockActive = false
    private var presenceWasEnabledBeforeAmbientLock = false
    private var autoLightWasEnabledBeforeAmbientLock = false
    private var isScreenSleepPresenceLockActive = false
    private var presenceWasEnabledBeforeScreenSleep = false

    init(isAsleep: Bool, lamp: LampController) {
        self.lamp = lamp
        self.isAsleep = isAsleep
        isBrightnessFollowEnabled = UserDefaults.standard.bool(forKey: "brightnessFollowEnabled")
        isPowerSyncEnabled = UserDefaults.standard.object(forKey: "powerSyncEnabled") as? Bool ?? true
        isTimeTemperatureEnabled = UserDefaults.standard.bool(forKey: "timeTemperatureEnabled")
        ambientCloseThreshold = UserDefaults.standard.object(forKey: "ambientCloseThreshold") as? Int
        ambientOpenThreshold = UserDefaults.standard.object(forKey: "ambientOpenThreshold") as? Int
        ambientThresholdSource = UserDefaults.standard.string(forKey: "ambientThresholdSource")
        areAmbientRulesEnabled = UserDefaults.standard.object(forKey: "ambientRulesEnabled") as? Bool
            ?? (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
        UserDefaults.standard.removeObject(forKey: "ambientLinkEnabled")
        if ambientThresholdSource != "studioDisplayALS-v1" {
            ambientCloseThreshold = nil
            ambientOpenThreshold = nil
            areAmbientRulesEnabled = false
        }
        presenceWasEnabledBeforeAmbientLock = UserDefaults.standard.bool(forKey: "ambientSuspendedPresenceWasEnabled")
        autoLightWasEnabledBeforeAmbientLock = UserDefaults.standard.bool(forKey: "ambientSuspendedAutoLightWasEnabled")
        isAmbientPresenceLockActive = presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock
        presenceWasEnabledBeforeScreenSleep = UserDefaults.standard.bool(forKey: "screenSleepSuspendedPresenceWasEnabled")
        isScreenSleepPresenceLockActive = presenceWasEnabledBeforeScreenSleep
        presenceDelaySeconds = UserDefaults.standard.object(forKey: "presenceDelaySeconds") as? Int ?? 180
        if !presenceDelayOptions.contains(presenceDelaySeconds) {
            presenceDelaySeconds = 180
        }
        presenceSensitivity = UserDefaults.standard.object(forKey: "presenceSensitivity") as? Int ?? 2
        presenceSensitivity = max(0, min(2, presenceSensitivity))
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        configurePanel()
        configureMenu()
        update(isAsleep: isAsleep, healthy: true)
    }

    func update(isAsleep: Bool, healthy: Bool) {
        self.isAsleep = isAsleep
        isHealthy = healthy
        if lamp.isAutoLightEnabled == true, isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = false
            brightnessFollowSwitch.state = .off
            UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            log("检测到灯具自动感光已开启，已自动关闭 Studio Display 亮度跟随")
        }
        updateIcon(healthy: healthy)
        let displayState = isAsleep ? "Studio Display 已熄屏" : "Studio Display 已唤醒"
        let brightnessStatus = isBrightnessFollowEnabled ? "亮度跟随已开启" : "亮度跟随已关闭"
        let powerStatus = isPowerSyncEnabled ? "熄屏同步已开启" : "熄屏同步已关闭"
        let status = healthy ? L("In sync") : L("Sync error")
        _ = (displayState, brightnessStatus, powerStatus)
        let brightnessText = healthy ? lamp.currentBrightness.map { "\($0)%" } ?? "--%" : "--%"
        let temperatureText = healthy ? lamp.currentTemperature.map { "\($0)K" } ?? "----K" : "----K"
        item.button?.toolTip = "\(brightnessText) · \(temperatureText)"
        item.button?.setAccessibilityLabel("iScreen Menu \(status)")
        if isMenuOpen { refreshControls() }
    }

    private func configureMenu() {
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        item.menu = statusMenu
    }

    func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }

    func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        lamp.requestStatus()
        refreshControls()
        menu.removeAllItems()

        menu.addItem(panelMenuItem)

        menu.addItem(.separator())
        menu.addItem(presenceMenuItem())
        menu.addItem(ambientMenuItem())
        menu.addItem(modePresetMenuItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Quit iScreen Menu"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    /// 把面板中的按钮映射为菜单项；按钮本身仍保存状态并承载原有的 action。
    private func menuItem(for button: NSButton, toggle: Bool = true, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? button.title, action: #selector(menuButtonClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = button
        item.tag = toggle ? 1 : 0
        item.image = button.image
        item.state = toggle ? button.state : .off
        item.isEnabled = button.isEnabled
        item.toolTip = button.toolTip
        return item
    }

    @objc private func menuButtonClicked(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton, let action = button.action else { return }
        if sender.tag == 1 { button.state = button.state == .on ? .off : .on }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    @objc private func popupOptionSelected(_ sender: NSMenuItem) {
        guard let popup = sender.representedObject as? NSPopUpButton, let action = popup.action else { return }
        popup.selectItem(withTag: sender.tag)
        NSApp.sendAction(action, to: popup.target, from: popup)
    }

    private func presenceMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("Presence Settings"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "figure.seated.side", accessibilityDescription: L("Presence"))
        parent.isEnabled = presenceDelayPopup.isEnabled
        let submenu = NSMenu()
        for (title, popup) in [(L("Away Time"), presenceDelayPopup), (L("Sensitivity"), presenceSensitivityPopup)] {
            submenu.addItem(.sectionHeader(title: title))
            for option in popup.itemArray {
                let item = NSMenuItem(title: option.title, action: #selector(popupOptionSelected(_:)), keyEquivalent: "")
                item.target = self
                item.tag = option.tag
                item.representedObject = popup
                item.state = option === popup.selectedItem ? .on : .off
                submenu.addItem(item)
            }
        }
        parent.submenu = submenu
        return parent
    }

    private func ambientMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("Ambient Light Calibration"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: L("Ambient Light Calibration"))
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(menuItem(for: ambientEnableSwitch, title: L("Turn Light On/Off by Ambient Light")))
        submenu.addItem(.separator())
        submenu.addItem(menuItem(for: captureBrightButton, toggle: false,
                                 title: String(format: L("Set Current Light as Off Point (%@)"), brightThresholdLabel.stringValue)))
        submenu.addItem(menuItem(for: captureDarkButton, toggle: false,
                                 title: String(format: L("Set Current Light as On Point (%@)"), darkThresholdLabel.stringValue)))
        submenu.addItem(.separator())
        let status = NSMenuItem(title: ambientStatusLabel.stringValue, action: nil, keyEquivalent: "")
        status.isEnabled = false
        ambientStatusItem = status
        submenu.addItem(status)
        parent.submenu = submenu
        return parent
    }

    private func modePresetMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: String(format: L("Light Preset: %@"), modeButton.title), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "lightbulb", accessibilityDescription: L("Light Presets"))
        let submenu = NSMenu()
        for (index, title) in modeNames().enumerated() {
            let item = NSMenuItem(title: title, action: #selector(presetChanged(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if title == modeButton.title { item.state = .on }
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let center = NSMenuItem(title: L("Mode Center…"), action: #selector(showModeCenter), keyEquivalent: "")
        center.target = self
        submenu.addItem(center)
        parent.submenu = submenu
        return parent
    }

    @objc private func powerChanged() {
        let requested = powerSwitch.state == .on
        if !lamp.setPower(on: requested) { powerSwitch.state = requested ? .off : .on }
        updateIcon(healthy: isHealthy && lamp.isConnected)
        refreshControls()
        lamp.requestStatus()
    }

    @objc private func captureBrightThreshold() {
        guard let value = currentDisplayAmbientProxy else {
            captureBrightButton.state = .off
            ambientStatusLabel.stringValue = L("Cannot read the Studio Display light sensor right now")
            NSSound.beep()
            return
        }
        ambientCloseThreshold = value
        UserDefaults.standard.set(value, forKey: "ambientCloseThreshold")
        ambientThresholdSource = "studioDisplayALS-v1"
        UserDefaults.standard.set("studioDisplayALS-v1", forKey: "ambientThresholdSource")
        updateAmbientStatusLabel()
        flashCaptureSuccess(button: captureBrightButton, valueLabel: brightThresholdLabel)
        log("已采集环境关灯点：\(currentAmbientSourceName) 响应分数 \(value)")
    }

    @objc private func captureDarkThreshold() {
        guard let value = currentDisplayAmbientProxy else {
            captureDarkButton.state = .off
            ambientStatusLabel.stringValue = L("Cannot read the Studio Display light sensor right now")
            NSSound.beep()
            return
        }
        ambientOpenThreshold = value
        UserDefaults.standard.set(value, forKey: "ambientOpenThreshold")
        ambientThresholdSource = "studioDisplayALS-v1"
        UserDefaults.standard.set("studioDisplayALS-v1", forKey: "ambientThresholdSource")
        updateAmbientStatusLabel()
        flashCaptureSuccess(button: captureDarkButton, valueLabel: darkThresholdLabel)
        log("已采集环境开灯点：\(currentAmbientSourceName) 响应分数 \(value)")
    }

    private func flashCaptureSuccess(button: FeatureButton, valueLabel: NSTextField) {
        button.state = .on
        valueLabel.textColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak button, weak valueLabel] in
            button?.state = .off
            valueLabel?.textColor = .secondaryLabelColor
        }
    }

    @objc private func ambientEnableChanged() {
        areAmbientRulesEnabled = ambientEnableSwitch.state == .on
        UserDefaults.standard.set(areAmbientRulesEnabled, forKey: "ambientRulesEnabled")
        updateAmbientStatusLabel()
        log(areAmbientRulesEnabled ? "已启用保存的环境光规则" : "已停用环境光规则，保留标定数值")
    }

    func updateDisplayAmbientProxy(_ value: Int?, sourceName: String) {
        currentDisplayAmbientProxy = value
        currentAmbientSourceName = sourceName
        if isMenuOpen { updateAmbientStatusLabel() }
    }

    @discardableResult
    func suspendPresenceForAmbientLock() -> Bool {
        if isAmbientPresenceLockActive {
            maintainPresenceSuspendedForAmbientLock()
            return true
        }
        isAmbientPresenceLockActive = true
        presenceWasEnabledBeforeAmbientLock = presenceWasEnabledBeforeAmbientLock || lamp.isPresenceDetectionEnabled == true
        autoLightWasEnabledBeforeAmbientLock = autoLightWasEnabledBeforeAmbientLock || lamp.isAutoLightEnabled == true
        if autoLightWasEnabledBeforeAmbientLock {
            guard lamp.setAutoLight(enabled: false) else {
                isAmbientPresenceLockActive = false
                autoLightWasEnabledBeforeAmbientLock = false
                return false
            }
            UserDefaults.standard.set(true, forKey: "ambientSuspendedAutoLightWasEnabled")
            log("环境关灯锁定已临时暂停自动感光")
        }
        if presenceWasEnabledBeforeAmbientLock {
            guard lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                            sensitivity: presenceSensitivity) else {
                if autoLightWasEnabledBeforeAmbientLock {
                    _ = lamp.setAutoLight(enabled: true)
                    UserDefaults.standard.removeObject(forKey: "ambientSuspendedAutoLightWasEnabled")
                }
                isAmbientPresenceLockActive = false
                presenceWasEnabledBeforeAmbientLock = false
                autoLightWasEnabledBeforeAmbientLock = false
                return false
            }
            UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
            log("环境关灯锁定已临时暂停入座检测")
        }
        refreshControls()
        return true
    }

    func maintainPresenceSuspendedForAmbientLock() {
        guard isAmbientPresenceLockActive else { return }
        // 灯体关闭时，固件不会应用“写入手动亮度”这个退出自动感光动作。
        // 旧版留下的关灯锁定只记住恢复意图；若灯体自行亮起，再立即暂停。
        if lamp.isPowerOn == true, lamp.isAutoLightEnabled == true {
            autoLightWasEnabledBeforeAmbientLock = true
            if lamp.setAutoLight(enabled: false) {
                UserDefaults.standard.set(true, forKey: "ambientSuspendedAutoLightWasEnabled")
                log("检测到环境锁定期间自动感光仍开启，已临时暂停")
            }
        }
        if lamp.isPresenceDetectionEnabled == true {
            presenceWasEnabledBeforeAmbientLock = true
            if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
                log("检测到环境锁定期间入座检测仍开启，已临时暂停")
            }
        }
    }

    func restorePresenceAfterAmbientLock() {
        guard isAmbientPresenceLockActive || presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock else { return }
        let shouldRestorePresence = presenceWasEnabledBeforeAmbientLock
        let shouldRestoreAutoLight = autoLightWasEnabledBeforeAmbientLock
        isAmbientPresenceLockActive = false
        presenceWasEnabledBeforeAmbientLock = false
        autoLightWasEnabledBeforeAmbientLock = false
        UserDefaults.standard.removeObject(forKey: "ambientSuspendedPresenceWasEnabled")
        UserDefaults.standard.removeObject(forKey: "ambientSuspendedAutoLightWasEnabled")
        if shouldRestorePresence, isScreenSleepPresenceLockActive {
            presenceWasEnabledBeforeScreenSleep = true
            UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
        } else if shouldRestorePresence {
            if lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                log("环境关灯锁定已解除，已恢复入座检测")
            } else {
                log("环境关灯锁定已解除，但入座检测恢复失败")
            }
        }
        if shouldRestoreAutoLight {
            if lamp.setAutoLight(enabled: true) {
                log("环境关灯锁定已解除，已恢复自动感光")
            } else {
                log("环境关灯锁定已解除，但自动感光恢复失败")
            }
        }
        refreshControls()
    }

    func suspendPresenceForScreenSleep() {
        if isScreenSleepPresenceLockActive {
            if lamp.isPresenceDetectionEnabled == true {
                presenceWasEnabledBeforeScreenSleep = true
                if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                             sensitivity: presenceSensitivity) {
                    UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
                    log("检测到熄屏期间入座检测仍开启，已重新暂停")
                }
            }
            return
        }
        // 环境关灯锁定已经暂停时，由环境锁负责恢复，避免唤醒时抢先开启。
        guard !isAmbientPresenceLockActive else { return }
        isScreenSleepPresenceLockActive = true
        presenceWasEnabledBeforeScreenSleep = lamp.isPresenceDetectionEnabled == true
        guard presenceWasEnabledBeforeScreenSleep else { return }
        if lamp.setPresenceDetection(enabled: false, delaySeconds: presenceDelaySeconds,
                                     sensitivity: presenceSensitivity) {
            UserDefaults.standard.set(true, forKey: "screenSleepSuspendedPresenceWasEnabled")
            log("熄屏同步已临时暂停入座检测")
        } else {
            isScreenSleepPresenceLockActive = false
            presenceWasEnabledBeforeScreenSleep = false
            log("熄屏时暂停入座检测失败")
        }
        refreshControls()
    }

    func restorePresenceAfterScreenWake() {
        guard isScreenSleepPresenceLockActive || presenceWasEnabledBeforeScreenSleep else { return }
        let shouldRestore = presenceWasEnabledBeforeScreenSleep
        isScreenSleepPresenceLockActive = false
        presenceWasEnabledBeforeScreenSleep = false
        UserDefaults.standard.removeObject(forKey: "screenSleepSuspendedPresenceWasEnabled")
        if shouldRestore, isAmbientPresenceLockActive {
            presenceWasEnabledBeforeAmbientLock = true
            UserDefaults.standard.set(true, forKey: "ambientSuspendedPresenceWasEnabled")
        }
        if shouldRestore, !isAmbientPresenceLockActive {
            if lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds,
                                         sensitivity: presenceSensitivity) {
                log("屏幕已唤醒，已恢复入座检测")
            } else {
                log("屏幕已唤醒，但入座检测恢复失败")
            }
        }
        refreshControls()
    }

    var hasPendingAmbientPresenceRestore: Bool {
        return presenceWasEnabledBeforeAmbientLock || autoLightWasEnabledBeforeAmbientLock
    }

    private func updateAmbientStatusLabel() {
        brightThresholdLabel.stringValue = ambientCloseThreshold.map(String.init) ?? "--"
        darkThresholdLabel.stringValue = ambientOpenThreshold.map(String.init) ?? "--"
        captureBrightButton.state = .off
        captureDarkButton.state = .off
        ambientEnableSwitch.state = areAmbientRulesEnabled ? .on : .off
        ambientEnableSwitch.isEnabled = currentDisplayAmbientProxy != nil &&
            (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
        let currentText = currentDisplayAmbientProxy.map { String(format: L("Ambient %d"), $0) } ?? L("Ambient --")
        if let close = ambientCloseThreshold, let open = ambientOpenThreshold, open >= close {
            ambientStatusLabel.stringValue = "\(currentText)  ·  " + L("Thresholds overlap; the light may toggle repeatedly")
        } else if !areAmbientRulesEnabled, ambientCloseThreshold != nil || ambientOpenThreshold != nil {
            ambientStatusLabel.stringValue = "\(currentText)  ·  " + L("Saved, not enabled")
        } else {
            ambientStatusLabel.stringValue = currentText
        }
        ambientStatusItem?.title = ambientStatusLabel.stringValue
    }

    var isAmbientLinkEnabled: Bool {
        return areAmbientRulesEnabled && (ambientCloseThreshold != nil || ambientOpenThreshold != nil)
    }

    @objc private func brightnessChanged() {
        let value = Int(brightnessSlider.doubleValue.rounded())
        // 与色温相同：拖动中按节流间隔写入亮度，松开时再刷新界面并回读状态。
        if brightnessSlider.isTracking {
            let now = Date()
            guard value != lamp.currentBrightness,
                  now.timeIntervalSince(lastDragBrightnessSentAt) >= 0.05 else { return }
            lastDragBrightnessSentAt = now
            withLampOn("brightness") { [weak self] in
                _ = self?.lamp.setBrightness(value)
            }
            return
        }
        lastDragBrightnessSentAt = .distantPast
        withLampOn("brightness") { [weak self] in
            guard let self else { return }
            _ = self.lamp.setBrightness(value)
            self.refreshControls()
            self.lamp.requestStatus()
        }
    }

    @objc private func temperatureChanged() {
        let value = Int((temperatureSlider.doubleValue / 100).rounded()) * 100
        // 拖动中标记随指针连续移动，只按节流间隔写入色温，让灯实时跟随；松开时再对齐、刷新界面并回读状态。
        if temperatureSlider.isTracking {
            let now = Date()
            guard value != lamp.currentTemperature,
                  now.timeIntervalSince(lastDragTemperatureSentAt) >= 0.05 else { return }
            lastDragTemperatureSentAt = now
            withLampOn("temperature") { [weak self] in
                _ = self?.lamp.setTemperature(value)
            }
            return
        }
        temperatureSlider.doubleValue = Double(value)
        lastDragTemperatureSentAt = .distantPast
        withLampOn("temperature") { [weak self] in
            guard let self else { return }
            _ = self.lamp.setTemperature(value)
            self.refreshControls()
            self.lamp.requestStatus()
        }
    }

    /// 灯关闭时固件会忽略亮度、色温与自动感光指令：先开灯，稍候再执行调整。
    /// 等待期间同一 key 的请求只保留最新一次；环境光规则正在关灯时不开灯。
    private func withLampOn(_ key: String, _ action: @escaping () -> Void) {
        if isWaitingForLampOn {
            pendingLampOnActions.removeAll { $0.key == key }
            pendingLampOnActions.append((key, action))
            return
        }
        guard lamp.isPowerOn != true else {
            action()
            return
        }
        let ambientHoldsLampOff = isAmbientPresenceLockActive || UserDefaults.standard.bool(forKey: "ambientLampLockActive")
        guard !ambientHoldsLampOff, lamp.setPower(on: true) else {
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            refreshControls()
            return
        }
        isWaitingForLampOn = true
        pendingLampOnActions = [(key, action)]
        updateIcon(healthy: isHealthy && lamp.isConnected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let actions = self.pendingLampOnActions
            self.pendingLampOnActions.removeAll()
            self.isWaitingForLampOn = false
            actions.forEach { $0.action() }
        }
    }

    @objc private func timeTemperatureChanged() {
        isTimeTemperatureEnabled = timeTemperatureSwitch.state == .on
        UserDefaults.standard.set(isTimeTemperatureEnabled, forKey: "timeTemperatureEnabled")
        lastScheduledTemperature = nil
        lastScheduledTemperatureChangeAt = .distantPast
        refreshControls()
        if isTimeTemperatureEnabled {
            applyScheduledTemperatureIfNeeded(isAsleep: isAsleep, force: true)
            log("已开启色温随时间")
        } else {
            log("已关闭色温随时间，保持当前色温")
        }
    }

    func applyScheduledTemperatureIfNeeded(isAsleep: Bool, force: Bool = false) {
        guard isTimeTemperatureEnabled,
              !isAsleep,
              lamp.isConnected,
              lamp.isPowerOn == true else { return }
        let target = scheduledTemperature(at: Date())
        guard force || target != lastScheduledTemperature || lamp.currentTemperature != target else { return }
        guard force || Date().timeIntervalSince(lastScheduledTemperatureChangeAt) >= 60 else { return }
        if lamp.setTemperature(target) {
            lastScheduledTemperature = target
            lastScheduledTemperatureChangeAt = Date()
            log("色温随时间已调整为 \(target)K")
        }
    }

    private func scheduledTemperature(at date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let value: Double
        switch minute {
        case 0..<(6 * 60):
            value = 3000
        case (6 * 60)..<(10 * 60):
            value = interpolate(minute: minute, from: 6 * 60, to: 10 * 60, start: 3000, end: 5500)
        case (10 * 60)..<(16 * 60):
            value = 5500
        case (16 * 60)..<(21 * 60):
            value = interpolate(minute: minute, from: 16 * 60, to: 21 * 60, start: 5500, end: 3500)
        default:
            value = interpolate(minute: minute, from: 21 * 60, to: 24 * 60, start: 3500, end: 3000)
        }
        return max(2700, min(6500, Int((value / 50).rounded()) * 50))
    }

    private func interpolate(minute: Int, from: Int, to: Int, start: Double, end: Double) -> Double {
        let progress = Double(minute - from) / Double(to - from)
        return start + (end - start) * max(0, min(1, progress))
    }

    @objc private func autoLightChanged() {
        let requested = autoLightSwitch.state == .on
        autoLightChangePendingUntil = Date().addingTimeInterval(1.5)
        pendingAutoLightState = requested
        withLampOn("autoLight") { [weak self] in self?.applyAutoLight(requested) }
    }

    private func applyAutoLight(_ requested: Bool) {
        if !lamp.setAutoLight(enabled: requested) {
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            refreshControls()
            return
        }
        autoLightChangePendingUntil = Date().addingTimeInterval(1)
        if requested, isBrightnessFollowEnabled {
            isBrightnessFollowEnabled = false
            brightnessFollowSwitch.state = .off
            UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
            update(isAsleep: isAsleep, healthy: isHealthy)
            log("已关闭 Studio Display 亮度跟随，改用灯具自动感光")
        }
        refreshControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.lamp.requestStatus()
        }
    }

    @objc private func presenceChanged() {
        let requested = presenceSwitch.state == .on
        if !lamp.setPresenceDetection(enabled: requested, delaySeconds: presenceDelaySeconds, sensitivity: presenceSensitivity) {
            presenceSwitch.state = requested ? .off : .on
        }
        lamp.requestStatus()
    }

    @objc private func presenceDelayChanged() {
        let seconds = selectedPresenceDelaySeconds()
        presenceDelaySeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "presenceDelaySeconds")
        log("入座检测时间设置为 \(seconds) 秒")
        if lamp.isPresenceDetectionEnabled == true {
            let requested = presenceSwitch.state == .on
            if !lamp.setPresenceDetection(enabled: requested, delaySeconds: seconds, sensitivity: presenceSensitivity) {
                log("入座检测时间未成功下发到灯具，已保持本地设置")
            }
            lamp.requestStatus()
        }
    }

    @objc private func presenceSensitivityChanged() {
        presenceSensitivity = presenceSensitivityPopup.selectedItem?.tag ?? 2
        UserDefaults.standard.set(presenceSensitivity, forKey: "presenceSensitivity")
        log("离席侦测灵敏度设置为 \(presenceSensitivityPopup.titleOfSelectedItem ?? "高")")
        if lamp.isPresenceDetectionEnabled == true {
            if !lamp.setPresenceDetection(enabled: true, delaySeconds: presenceDelaySeconds, sensitivity: presenceSensitivity) {
                log("离席侦测灵敏度未成功下发到灯具，已保持本地设置")
            }
            lamp.requestStatus()
        }
    }

    @objc private func videoModeChanged() {
        let requested = videoModeSwitch.state == .on
        if !lamp.setVideoMode(enabled: requested) {
            videoModeSwitch.state = requested ? .off : .on
        }
        lamp.requestStatus()
    }

    @objc private func presetChanged(_ sender: NSMenuItem) {
        let index = sender.tag
        let title = sender.title
        let preset: (brightness: Int, temperature: Int, video: Bool)
        if (index == 0 || index >= 3),
           let data = UserDefaults.standard.data(forKey: "savedCustomMode"),
           let saved = try? JSONDecoder().decode(SavedMode.self, from: data) {
            preset = (saved.brightness, saved.temperature, saved.videoMode)
        } else {
            switch index {
            case 1: preset = (30, 4000, false)
            case 2: preset = (20, 3000, false)
            default: preset = (47, 5500, false)
            }
        }
        isBrightnessFollowEnabled = false
        brightnessFollowSwitch.state = .off
        UserDefaults.standard.set(false, forKey: "brightnessFollowEnabled")
        withLampOn("preset") { [weak self] in
            guard let self else { return }
            _ = self.lamp.setBrightness(preset.brightness)
            _ = self.lamp.setTemperature(preset.temperature)
            _ = self.lamp.setVideoMode(enabled: preset.video)
            self.refreshControls()
            self.modeButton.title = title
            log("已应用模式预设：\(title)")
            self.lamp.requestStatus()
        }
    }

    private func modeNames() -> [String] {
        var names = [L("My Favorite"), L("Night Work"), L("Wind Down")]
        if let data = UserDefaults.standard.data(forKey: "savedCustomMode"),
           let mode = try? JSONDecoder().decode(SavedMode.self, from: data),
           !names.contains(mode.name) {
            names.append(mode.name)
        }
        return names
    }

    @objc private func showModeCenter() {
        if let window = modeCenterWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 270),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Mode Center")
        let title = NSTextField(labelWithString: L("Mode Center"))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L("Quickly switch between lighting scenes"))
        subtitle.font = UIStyle.bodyFont
        subtitle.textColor = .secondaryLabelColor
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 1
        rows.wantsLayer = true
        rows.layer?.cornerRadius = 10
        rows.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        for (index, name) in modeNames().enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(modeCenterPresetChanged(_:)))
            button.tag = index
            button.isBordered = false
            button.setAccessibilityTitle(name)
            button.translatesAutoresizingMaskIntoConstraints = false
            let label = NSTextField(labelWithString: name)
            label.font = UIStyle.bodyFont
            label.translatesAutoresizingMaskIntoConstraints = false
            let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            chevron.translatesAutoresizingMaskIntoConstraints = false
            let row = NSView()
            row.addSubview(button)
            row.addSubview(label)
            row.addSubview(chevron)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 44),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 10),
                chevron.heightAnchor.constraint(equalToConstant: 14)
            ])
            rows.addArrangedSubview(row)
        }
        let add = NSButton(title: L("Add Scene"), target: self, action: #selector(saveCurrentMode))
        add.bezelStyle = .rounded
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        let bind = NSButton(title: L("Bind to App"), target: self, action: #selector(bindCurrentModeToApp))
        bind.bezelStyle = .rounded
        bind.image = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil)
        bind.imagePosition = .imageLeading
        let leadingSpace = NSView()
        let trailingSpace = NSView()
        leadingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailingSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [leadingSpace, add, bind, trailingSpace])
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.distribution = .fill
        actions.widthAnchor.constraint(equalToConstant: 512).isActive = true
        leadingSpace.widthAnchor.constraint(equalTo: trailingSpace.widthAnchor).isActive = true
        let stack = NSStackView(views: [title, subtitle, rows, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            rows.widthAnchor.constraint(equalToConstant: 512)
        ])
        window.contentView = content
        window.isReleasedWhenClosed = false
        if let screen = item.button?.window?.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let frame = window.frame
            window.setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                          y: visible.midY - frame.height / 2))
        } else {
            window.center()
        }
        modeCenterWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func modeCenterPresetChanged(_ sender: NSButton) {
        let item = NSMenuItem(title: modeNames()[sender.tag], action: nil, keyEquivalent: "")
        item.tag = sender.tag
        presetChanged(item)
    }

    @objc private func saveCurrentMode() {
        guard let brightness = lamp.currentBrightness,
              let temperature = lamp.currentTemperature else {
            log("尚未获取灯具状态，无法保存模式")
            return
        }
        let alert = NSAlert()
        alert.messageText = L("Save New Mode")
        alert.informativeText = L("Saves the current brightness, color temperature and video mode.")
        let field = NSTextField(string: L("My Mode"))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let mode = SavedMode(name: field.stringValue.isEmpty ? L("My Mode") : field.stringValue,
                             brightness: brightness,
                             temperature: temperature,
                             videoMode: lamp.isVideoModeEnabled == true)
        if let data = try? JSONEncoder().encode(mode) {
            UserDefaults.standard.set(data, forKey: "savedCustomMode")
            modeButton.title = mode.name
            log("已保存模式：\(mode.name)")
            modeCenterWindow?.close()
            modeCenterWindow = nil
        }
    }

    @objc private func bindCurrentModeToApp() {
        guard let brightness = lamp.currentBrightness,
              let temperature = lamp.currentTemperature else { return }
        let panel = NSOpenPanel()
        panel.title = L("Choose an App to Bind")
        panel.prompt = L("Bind")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let mode = SavedMode(name: url.deletingPathExtension().lastPathComponent,
                             brightness: brightness,
                             temperature: temperature,
                             videoMode: lamp.isVideoModeEnabled == true)
        var mappings = loadAppModes()
        mappings[bundleID] = mode
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "appModes")
            log("已绑定应用模式：\(mode.name)")
        }
    }

    func applyModeForFrontmostAppIfNeeded() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleID != lastFrontmostBundleID else { return }
        lastFrontmostBundleID = bundleID
        guard let mode = loadAppModes()[bundleID] else { return }
        withLampOn("preset") { [weak self] in
            guard let self else { return }
            _ = self.lamp.setBrightness(mode.brightness)
            _ = self.lamp.setTemperature(mode.temperature)
            _ = self.lamp.setVideoMode(enabled: mode.videoMode)
            log("已应用应用模式：\(mode.name)")
        }
    }

    private func loadAppModes() -> [String: SavedMode] {
        guard let data = UserDefaults.standard.data(forKey: "appModes") else { return [:] }
        return (try? JSONDecoder().decode([String: SavedMode].self, from: data)) ?? [:]
    }

    @objc private func brightnessFollowChanged() {
        let requested = brightnessFollowSwitch.state == .on
        if requested, lamp.isAutoLightEnabled == true {
            guard lamp.setAutoLight(enabled: false) else {
                brightnessFollowSwitch.state = .off
                log("关闭自动感光失败，未开启 Studio Display 亮度跟随")
                return
            }
            autoLightSwitch.state = .off
            autoLightChangePendingUntil = Date().addingTimeInterval(1)
            pendingAutoLightState = false
            lamp.requestStatus()
            log("已关闭自动感光，改用 Studio Display 亮度跟随")
        }
        isBrightnessFollowEnabled = requested
        UserDefaults.standard.set(isBrightnessFollowEnabled, forKey: "brightnessFollowEnabled")
        update(isAsleep: isAsleep, healthy: isHealthy)
        log(isBrightnessFollowEnabled ? "已开启 Studio Display 亮度跟随" : "已关闭 Studio Display 亮度跟随")
    }

    @objc private func powerSyncChanged() {
        isPowerSyncEnabled = powerSyncSwitch.state == .on
        UserDefaults.standard.set(isPowerSyncEnabled, forKey: "powerSyncEnabled")
        update(isAsleep: isAsleep, healthy: isHealthy)
        log(isPowerSyncEnabled ? "已开启熄屏电源同步" : "已关闭熄屏电源同步")
    }

    private func configurePanel() {
        powerSwitch.target = self
        powerSwitch.action = #selector(powerChanged)
        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        temperatureSlider.target = self
        temperatureSlider.action = #selector(temperatureChanged)
        temperatureSlider.isContinuous = true
        timeTemperatureSwitch.target = self
        timeTemperatureSwitch.action = #selector(timeTemperatureChanged)
        timeTemperatureSwitch.toolTip = L("Adjust color temperature automatically by time of day")
        autoLightSwitch.target = self
        autoLightSwitch.action = #selector(autoLightChanged)
        autoLightSwitch.toolTip = L("Turn the lamp’s auto light sensor on or off")
        presenceSwitch.target = self
        presenceSwitch.action = #selector(presenceChanged)
        for seconds in presenceDelayOptions {
            let title = String(format: L("%d min"), seconds / 60)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = seconds
            presenceDelayPopup.menu?.addItem(item)
        }
        presenceDelayPopup.target = self
        presenceDelayPopup.action = #selector(presenceDelayChanged)
        selectPresenceDelay(presenceDelaySeconds)
        for (title, value) in [(L("Low"), 0), (L("Medium"), 1), (L("High"), 2)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = value
            presenceSensitivityPopup.menu?.addItem(item)
        }
        presenceSensitivityPopup.selectItem(withTag: presenceSensitivity)
        presenceSensitivityPopup.target = self
        presenceSensitivityPopup.action = #selector(presenceSensitivityChanged)
        videoModeSwitch.target = self
        videoModeSwitch.action = #selector(videoModeChanged)
        modeButton.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        modeButton.imagePosition = .imageTrailing
        modeButton.alignment = .left
        modeButton.bezelStyle = .rounded
        modeButton.controlSize = .large
        modeButton.font = UIStyle.bodyFont
        brightnessFollowSwitch.target = self
        brightnessFollowSwitch.action = #selector(brightnessFollowChanged)
        timeTemperatureSwitch.detail = L("By time of day")
        brightnessFollowSwitch.detail = L("Tracks display")
        powerSyncSwitch.detail = L("Off on sleep")
        brightnessFollowSwitch.toolTip = L("Lamp brightness follows the Studio Display")
        powerSyncSwitch.toolTip = L("Turn the lamp off when the Studio Display sleeps")
        videoModeSwitch.toolTip = L("Fill light for video calls")
        powerSyncSwitch.target = self
        powerSyncSwitch.action = #selector(powerSyncChanged)
        captureBrightButton.target = self
        captureBrightButton.action = #selector(captureBrightThreshold)
        captureBrightButton.setButtonType(.momentaryPushIn)
        captureBrightButton.toolTip = L("Save the current ambient value as the bright turn-off point")
        captureDarkButton.target = self
        captureDarkButton.action = #selector(captureDarkThreshold)
        captureDarkButton.setButtonType(.momentaryPushIn)
        captureDarkButton.toolTip = L("Save the current ambient value as the dim turn-on point")
        ambientEnableSwitch.target = self
        ambientEnableSwitch.action = #selector(ambientEnableChanged)
        for label in [brightThresholdLabel, darkThresholdLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
        }
        ambientStatusLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        ambientStatusLabel.textColor = .secondaryLabelColor

        [presenceDelayPopup, presenceSensitivityPopup].forEach { $0.controlSize = .small }

        let title = NSTextField(labelWithString: "iScreenBar")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        connectionLabel.font = .systemFont(ofSize: 11)
        connectionLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [statusDot, connectionLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 5
        let titles = NSStackView(views: [title, status])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        powerSwitch.widthAnchor.constraint(equalToConstant: 32).isActive = true
        powerSwitch.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titles, headerSpacer, powerSwitch])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true

        for slider in [brightnessSlider, temperatureSlider] {
            slider.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
        }
        let sliders = NSStackView(views: [brightnessSlider, temperatureSlider])
        sliders.orientation = .vertical
        sliders.spacing = 8
        let toggles = toggleGrid([[autoLightSwitch, timeTemperatureSwitch], [presenceSwitch, videoModeSwitch],
                                  [brightnessFollowSwitch, powerSyncSwitch]])

        // 入座检测、环境光标定与灯光预设属于设置项，放在下方的原生子菜单中。
        let stack = NSStackView(views: [header, sliders, toggles])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // 滑块与开关方块的行距一致，构成同一组控件。
        stack.setCustomSpacing(sliders.spacing, after: sliders)
        stack.edgeInsets = NSEdgeInsets(top: 10, left: UIStyle.outerInset, bottom: 8, right: UIStyle.outerInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let panelView = NSView()
        panelView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panelView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panelView.bottomAnchor)
        ])
        panelView.frame = NSRect(origin: .zero, size: NSSize(width: UIStyle.panelWidth, height: stack.fittingSize.height))
        panelMenuItem.view = panelView
    }

    /// 开关卡片网格：每行等宽，两端与滑块边缘对齐，间距与滑块间距一致。
    private func toggleGrid(_ rows: [[FeatureButton]]) -> NSStackView {
        let rowViews: [NSView] = rows.map { buttons in
            let width = (UIStyle.contentWidth - 8 * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
            let tiles: [NSView] = buttons.map { button in
                let background = FrostedBackground(cornerRadius: UIStyle.controlRadius)
                button.translatesAutoresizingMaskIntoConstraints = false
                background.addSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: background.leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                    button.topAnchor.constraint(equalTo: background.topAnchor),
                    button.bottomAnchor.constraint(equalTo: background.bottomAnchor),
                    background.widthAnchor.constraint(equalToConstant: width),
                    background.heightAnchor.constraint(equalToConstant: UIStyle.controlHeight)
                ])
                return background
            }
            let row = NSStackView(views: tiles)
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .top
            row.widthAnchor.constraint(equalToConstant: UIStyle.contentWidth).isActive = true
            return row
        }
        let grid = NSStackView(views: rowViews)
        grid.orientation = .vertical
        grid.spacing = 8
        return grid
    }

    private func refreshControls() {
        powerSwitch.state = lamp.isPowerOn == true ? .on : .off
        let autoLightChangePending = autoLightChangePendingUntil.map { Date() < $0 } ?? false
        if isAmbientPresenceLockActive {
            autoLightSwitch.title = autoLightWasEnabledBeforeAmbientLock ? L("Light Paused") : L("Auto Light")
            autoLightSwitch.state = autoLightWasEnabledBeforeAmbientLock ? .on : .off
            autoLightSwitch.toolTip = autoLightWasEnabledBeforeAmbientLock
                ? L("Paused while ambient light keeps the lamp off; resumes automatically")
                : L("Auto light can’t be turned on while ambient light keeps the lamp off")
        } else if autoLightChangePending, let pendingAutoLightState {
            autoLightSwitch.title = L("Auto Light")
            autoLightSwitch.state = pendingAutoLightState ? .on : .off
            autoLightSwitch.toolTip = pendingAutoLightState ? L("Turning auto light on") : L("Turning auto light off")
        } else if lamp.isAutoLightEnabled == true {
            autoLightSwitch.title = L("Auto Light")
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            autoLightSwitch.state = .on
            autoLightSwitch.toolTip = L("Turn auto light off")
        } else {
            autoLightSwitch.title = L("Auto Light")
            autoLightChangePendingUntil = nil
            pendingAutoLightState = nil
            autoLightSwitch.state = .off
            autoLightSwitch.toolTip = L("Turn auto light on")
        }
        if isAmbientPresenceLockActive || isScreenSleepPresenceLockActive {
            let wasEnabled = presenceWasEnabledBeforeAmbientLock || presenceWasEnabledBeforeScreenSleep
            presenceSwitch.title = wasEnabled ? L("Detect Paused") : L("Presence")
            presenceSwitch.state = wasEnabled ? .on : .off
            presenceSwitch.toolTip = wasEnabled
                ? L("Paused while the lamp is held off; resumes automatically")
                : L("Presence detection can’t be turned on while the lamp is held off")
        } else {
            presenceSwitch.title = L("Presence")
            presenceSwitch.state = lamp.isPresenceDetectionEnabled == true ? .on : .off
            presenceSwitch.toolTip = L("Turn the lamp’s presence detection on or off")
        }
        videoModeSwitch.state = lamp.isVideoModeEnabled == true ? .on : .off
        brightnessFollowSwitch.state = isBrightnessFollowEnabled ? .on : .off
        powerSyncSwitch.state = isPowerSyncEnabled ? .on : .off
        timeTemperatureSwitch.state = isTimeTemperatureEnabled ? .on : .off
        updateAmbientStatusLabel()
        selectPresenceDelay(presenceDelaySeconds)
        presenceSensitivityPopup.selectItem(withTag: presenceSensitivity)
        if let brightness = lamp.currentBrightness, !brightnessSlider.isTracking {
            brightnessSlider.doubleValue = Double(brightness)
        }
        if let temperature = lamp.currentTemperature, !temperatureSlider.isTracking {
            temperatureSlider.doubleValue = Double(temperature)
        }
        let enabled = lamp.isConnected
        powerSwitch.isEnabled = enabled
        let presencePaused = isAmbientPresenceLockActive || isScreenSleepPresenceLockActive
        presenceSwitch.detail = presencePaused ? L("Paused") : String(format: L("%d min away"), presenceDelaySeconds / 60)
        if !enabled {
            statusDot.color = .tertiaryLabelColor
            connectionLabel.stringValue = L("Not connected")
        } else if !isHealthy {
            statusDot.color = .systemOrange
            connectionLabel.stringValue = L("Sync error")
        } else {
            statusDot.color = .systemGreen
            switch lamp.isPowerOn {
            case true?:
                let values = [lamp.currentBrightness.map { "\($0)%" }, lamp.currentTemperature.map { "\($0)K" }]
                connectionLabel.stringValue = ([L("Connected")] + values.compactMap { $0 }).joined(separator: " · ")
            case false?: connectionLabel.stringValue = L("Connected · Light off")
            case nil: connectionLabel.stringValue = L("Connected")
            }
        }
        autoLightSwitch.isEnabled = enabled && !isAmbientPresenceLockActive
        // 自动感光由灯体自行调节亮度，期间手动亮度无效，与自动色温时的色温滑块一致置灰。
        brightnessSlider.isEnabled = enabled && lamp.isAutoLightEnabled != true
        temperatureSlider.isEnabled = enabled && !isTimeTemperatureEnabled
        timeTemperatureSwitch.isEnabled = enabled
        presenceSwitch.isEnabled = enabled && !isAmbientPresenceLockActive && !isScreenSleepPresenceLockActive
        videoModeSwitch.isEnabled = enabled
        powerSyncSwitch.isEnabled = enabled
        captureBrightButton.isEnabled = currentDisplayAmbientProxy != nil
        captureDarkButton.isEnabled = currentDisplayAmbientProxy != nil
        presenceDelayPopup.isEnabled = enabled
        presenceSensitivityPopup.isEnabled = enabled
    }

    private func updateIcon(healthy: Bool) {
        let level = lamp.isConnected && lamp.isPowerOn == true ? lamp.currentBrightness ?? 100 : 0
        let key = "\(level)-\(healthy)"
        if key != iconKey {
            iconKey = key
            item.button?.attributedTitle = NSAttributedString(string: "")
            item.button?.image = brightnessStatusIcon(level: level, warning: !healthy)
        }
    }

    private func selectPresenceDelay(_ seconds: Int) {
        if let item = presenceDelayPopup.menu?.item(withTag: seconds) {
            presenceDelayPopup.select(item)
            return
        }
        if let fallback = presenceDelayPopup.itemArray.first(where: { $0.tag == 180 }) {
            presenceDelayPopup.select(fallback)
        }
    }

    private func selectedPresenceDelaySeconds() -> Int {
        return presenceDelayPopup.selectedItem?.tag ?? presenceDelaySeconds
    }

}

private final class LampController {
    private var manager: IOHIDManager
    private var device: IOHIDDevice?
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private(set) var currentBrightness: Int?
    private(set) var currentTemperature: Int?
    private(set) var isPowerOn: Bool?
    private(set) var isAutoLightEnabled: Bool?
    private(set) var isPresenceDetectionEnabled: Bool?
    private(set) var isVideoModeEnabled: Bool?
    private(set) var statusRevision = 0
    private var lastTemperatureValues: (Int, Int)?
    private var lastStatusHex: String?

    var isConnected: Bool { device != nil }

    init() {
        manager = Self.makeManager()
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("无法打开 iScreenBar USB HID 设备")
            return
        }
        guard attachFirstDevice() else {
            log("未检测到 iScreenBar USB HID 设备，等待重新连接")
            return
        }
        _ = requestStatus()
    }

    deinit {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        inputBuffer.deallocate()
    }

    func setPower(on: Bool) -> Bool {
        if sendPowerReport(on: on) {
            isPowerOn = on
            log("灯已\(on ? "开启" : "关闭")")
            return true
        }

        log("USB HID 连接已失效，正在重新连接")
        guard reconnect(), sendPowerReport(on: on) else {
            log("USB HID 重连后指令仍失败")
            return false
        }

        isPowerOn = on
        log("重连成功，灯已\(on ? "开启" : "关闭")")
        return true
    }

    func setBrightness(_ brightness: Int) -> Bool {
        let value = UInt8(clamping: max(1, min(100, brightness)))
        guard sendCommand(0x04, payload: [value, value]) else { return false }
        currentBrightness = Int(value)
        log("灯亮度已调整为 \(brightness)%")
        return true
    }

    func setTemperature(_ temperature: Int) -> Bool {
        let value = max(2700, min(6500, temperature))
        let high = UInt8((value >> 8) & 0xFF)
        let low = UInt8(value & 0xFF)
        // iScreenBar 有主灯和背灯两组独立色温；两组都必须写入完整的 16 位 Kelvin 值。
        guard sendCommand(0x03, payload: [high, low, high, low]) else { return false }
        currentTemperature = value
        log("灯色温已调整为 \(value)K（主灯与背灯同步）")
        return true
    }

    func setAutoLight(enabled: Bool) -> Bool {
        if isAutoLightEnabled == enabled {
            return true
        }
        if enabled {
            // 官方 App 用 01 F0 01 04 F5 进入自动感光。
            guard sendCommand(0x01, payload: []) else { return false }
        } else {
            // 灯具固件不会用同一指令退出自动感光；官方控制逻辑通过写入手动亮度退出。
            guard let brightness = currentBrightness else {
                log("尚未获取当前亮度，无法关闭自动感光")
                return false
            }
            guard setBrightness(brightness) else { return false }
        }
        isAutoLightEnabled = enabled
        log(enabled ? "已开启自动感光" : "已关闭自动感光")
        return true
    }

    func setPresenceDetection(enabled: Bool, delaySeconds: Int, sensitivity: Int) -> Bool {
        let basePayload = [UInt8(enabled ? 1 : 0)]
        let delayMinutes = UInt8(clamping: delaySeconds / 60)
        let sensitivityValue = UInt8(clamping: max(0, min(2, sensitivity)))
        if !sendCommand(0x06, payload: basePayload + [delayMinutes, sensitivityValue]) {
            if !sendCommand(0x06, payload: basePayload) {
                return false
            }
            log("入座检测时间参数发送失败，已回退为仅开关命令")
        }
        isPresenceDetectionEnabled = enabled
        presenceDetectionDelaySeconds = delaySeconds
        log(enabled ? "已开启入座检测" : "已关闭入座检测")
        return true
    }

    private(set) var presenceDetectionDelaySeconds: Int?

    func setVideoMode(enabled: Bool) -> Bool {
        guard sendCommand(0x09, payload: [enabled ? 1 : 0]) else { return false }
        isVideoModeEnabled = enabled
        log(enabled ? "已开启视频模式" : "已关闭视频模式")
        return true
    }

    @discardableResult
    func requestStatus() -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = 0x20
        report[3] = 0x04
        report[4] = 0x14
        return send(report)
    }

    func checkConnection() -> Bool {
        if requestStatus() { return true }
        guard reconnect(), requestStatus() else { return false }
        log("USB HID 已重新连接")
        return true
    }

    private func sendPowerReport(on: Bool) -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = 0x07
        report[3] = 0x05
        report[4] = on ? 0xFD : 0xFC
        report[5] = on ? 0x01 : 0x00
        return send(report)
    }

    private func sendCommand(_ command: UInt8, payload: [UInt8]) -> Bool {
        var report = [UInt8](repeating: 0, count: 33)
        report[0] = 0x01
        report[1] = 0xF0
        report[2] = command
        report[3] = UInt8(payload.count + 4)
        report[4] = UInt8(truncatingIfNeeded: Int(report[1]) + Int(command) + Int(report[3]) + payload.reduce(0) { $0 + Int($1) })
        for (index, value) in payload.enumerated() {
            report[5 + index] = value
        }
        return send(report)
    }

    private func send(_ report: [UInt8]) -> Bool {
        guard let device else { return false }
        let result = report.withUnsafeBytes { bytes in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 1,
                                 bytes.bindMemory(to: UInt8.self).baseAddress!, report.count)
        }
        if result != kIOReturnSuccess {
            log(String(format: "USB HID 指令失败：0x%08X", result))
        }
        return result == kIOReturnSuccess
    }

    private func configureInputCallback(for device: IOHIDDevice) {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, 64,
            { context, _, _, _, _, report, reportLength in
                guard let context, reportLength >= 5 else { return }
                let controller = Unmanaged<LampController>.fromOpaque(context).takeUnretainedValue()
                if report[0] == 0x02, report[1] == 0xE1, report[2] == 0x20,
                   report[3] == 0x0D, reportLength >= 15 {
                    let statusHex = (0..<reportLength).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
                    if controller.lastStatusHex != statusHex {
                        controller.lastStatusHex = statusHex
                        log("状态原始报文：\(statusHex)")
                    }
                    controller.isPowerOn = (report[6] & 0x01) != 0
                    controller.isAutoLightEnabled = (report[6] & 0x04) != 0
                    controller.isPresenceDetectionEnabled = (report[6] & 0x20) != 0
                    controller.isVideoModeEnabled = (report[6] & 0x80) != 0
                    let mainTemperature = (Int(report[8]) << 8) | Int(report[9])
                    let backTemperature = (Int(report[11]) << 8) | Int(report[12])
                    if controller.lastTemperatureValues?.0 != mainTemperature ||
                        controller.lastTemperatureValues?.1 != backTemperature {
                        controller.lastTemperatureValues = (mainTemperature, backTemperature)
                        log("色温回读：主灯=\(mainTemperature)K，背灯=\(backTemperature)K")
                    }
                    controller.currentTemperature = mainTemperature
                    controller.currentBrightness = Int(report[10])
                    controller.statusRevision += 1
                }
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func reconnect() -> Bool {
        if let device {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        }
        device = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        return attachFirstDevice()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: benqVendorID,
            kIOHIDProductIDKey as String: iScreenBarProductID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return manager
    }

    private func attachFirstDevice() -> Bool {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let first = devices.first else { return false }
        device = first
        configureInputCallback(for: first)
        return true
    }
}

private final class DisplayBrightnessReader {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private let getter: GetBrightness?

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") {
            getter = unsafeBitCast(symbol, to: GetBrightness.self)
        } else {
            getter = nil
        }
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func percent(for displayID: CGDirectDisplayID) -> Int? {
        guard let getter else { return nil }
        var value: Float = 0
        guard getter(displayID, &value) == 0 else { return nil }
        return Int((max(0, min(1, value)) * 100).rounded())
    }
}

private final class StudioDisplayAmbientSensor {
    private var manager: IOHIDManager
    private var device: IOHIDDevice?
    private var illuminanceElement: IOHIDElement?
    private var lastReconnectAttempt = Date.distantPast

    init() {
        manager = Self.makeManager()
        guard openManager() else {
            log("无法打开 Studio Display 环境光传感器")
            return
        }
        _ = attachSensor()
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func rawIlluminance() -> Int? {
        if device == nil || illuminanceElement == nil,
           !attachSensor(),
           !reconnectIfNeeded() {
            return nil
        }
        if let value = readCurrentValue() { return value }

        // Studio Display 在锁屏、睡眠或显示器重新排列后会重建 HID 服务。
        // 旧 IOHIDDevice 对象仍可能存在，但 GetValue 会持续失败，必须重建 manager。
        device = nil
        illuminanceElement = nil
        guard reconnectIfNeeded() else { return nil }
        return readCurrentValue()
    }

    private static func makeManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x1118,
            kIOHIDPrimaryUsagePageKey as String: 0x20,
            kIOHIDPrimaryUsageKey as String: 0x41
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        return manager
    }

    private func openManager() -> Bool {
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
    }

    private func readCurrentValue() -> Int? {
        guard let device, let illuminanceElement else { return nil }
        var rawValue: Unmanaged<IOHIDValue> = .fromOpaque(UnsafeRawPointer(bitPattern: 1)!)
        guard IOHIDDeviceGetValue(device, illuminanceElement, &rawValue) == kIOReturnSuccess else {
            return nil
        }
        let raw = IOHIDValueGetIntegerValue(rawValue.takeUnretainedValue())
        // Studio Display 以约千分之一照度单位回传；转换为易读的相对环境分数。
        return max(0, raw / 1_000)
    }

    private func reconnectIfNeeded() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastReconnectAttempt) >= 2 else { return false }
        lastReconnectAttempt = now
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = Self.makeManager()
        guard openManager(), attachSensor() else { return false }
        log("Studio Display 环境光传感器已重新连接")
        return true
    }

    private func attachSensor() -> Bool {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return false }
        let elements = (IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? []
        guard let element = elements.first(where: {
            IOHIDElementGetUsagePage($0) == 0x20 && IOHIDElementGetUsage($0) == 0x04D1
        }) else { return false }
        self.device = device
        illuminanceElement = element
        return true
    }
}

private func studioDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
    return displays.prefix(Int(count)).first {
        CGDisplayIsBuiltin($0) == 0 &&
            CGDisplayIsOnline($0) != 0 &&
            CGDisplayVendorNumber($0) == appleDisplayVendorID &&
            (studioDisplayProductIDs.contains(CGDisplayModelNumber($0)) || isNamedStudioDisplay($0))
    }
}

private func isNamedStudioDisplay(_ id: CGDirectDisplayID) -> Bool {
    NSScreen.screens.contains {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id &&
            $0.localizedName.replacingOccurrences(of: " ", with: "").lowercased().contains("studiodisplay")
    }
}

var displayID = studioDisplayID()
private let lamp = LampController()
private let displayBrightnessReader = DisplayBrightnessReader()
private let studioAmbientSensor = StudioDisplayAmbientSensor()

if let displayID {
    log("开始监听 Studio Display ID=\(displayID)，分辨率=\(CGDisplayPixelsWide(displayID))x\(CGDisplayPixelsHigh(displayID))")
} else {
    log("未找到外接显示器，程序保持运行并等待 Studio Display 连接")
}
var wasAsleep = displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false
var helperTurnedLampOff = false
var ambientTurnedLampOff = UserDefaults.standard.bool(forKey: "ambientLampLockActive")
var ambientCloseCandidateSince: Date?
var ambientOpenCandidateSince: Date?
var ambientProxySamples: [(Date, Int)] = []
var ambientProxySourceName: String?
var lastLoggedAmbientProxy: Int?

private func setAmbientLampLock(_ active: Bool) {
    ambientTurnedLampOff = active
    if active {
        UserDefaults.standard.set(true, forKey: "ambientLampLockActive")
    } else {
        UserDefaults.standard.removeObject(forKey: "ambientLampLockActive")
    }
}
private let statusIndicator = StatusIndicator(isAsleep: wasAsleep, lamp: lamp)
if !wasAsleep {
    statusIndicator.restorePresenceAfterScreenWake()
}
var wasBrightnessFollowEnabled = statusIndicator.isBrightnessFollowEnabled
var wasPowerSyncEnabled = statusIndicator.isPowerSyncEnabled
var wasAmbientLinkEnabled = statusIndicator.isAmbientLinkEnabled
var wasAmbientCloseThreshold = statusIndicator.ambientCloseThreshold
var brightnessOffset: Int?
var anchorStatusRevision: Int?
var lastDisplayBrightness: Int?
var lastStatusRequest = Date.distantPast
var wasLampConnected = lamp.isConnected
if !wasAmbientLinkEnabled, ambientTurnedLampOff || statusIndicator.hasPendingAmbientPresenceRestore {
    if ambientTurnedLampOff, !wasAsleep { _ = lamp.setPower(on: true) }
    setAmbientLampLock(false)
    statusIndicator.restorePresenceAfterAmbientLock()
    log("已清理上次环境规则遗留的关灯与入座暂停状态")
}
if wasBrightnessFollowEnabled {
    anchorStatusRevision = lamp.statusRevision
    lamp.requestStatus()
    log("Studio Display 亮度跟随已开启，正在锁定当前亮度差")
}

private func pollDisplayAndLamp() {
    statusIndicator.applyModeForFrontmostAppIfNeeded()
    let detectedDisplayID = studioDisplayID()
    if detectedDisplayID != displayID {
        displayID = detectedDisplayID
        brightnessOffset = nil
        lastDisplayBrightness = nil
        anchorStatusRevision = nil
        if let displayID {
            wasAsleep = CGDisplayIsAsleep(displayID) != 0
            log("检测到 Studio Display 已连接：ID=\(displayID)，分辨率=\(CGDisplayPixelsWide(displayID))x\(CGDisplayPixelsHigh(displayID))")
        } else {
            wasAsleep = false
            log("Studio Display 已断开，程序继续驻留等待重连")
        }
    }
    let isAsleep = displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false
    let brightnessFollowEnabled = statusIndicator.isBrightnessFollowEnabled
    let powerSyncEnabled = statusIndicator.isPowerSyncEnabled
    let ambientLinkEnabled = statusIndicator.isAmbientLinkEnabled
    let ambientCloseThreshold = statusIndicator.ambientCloseThreshold
    let rawAmbientSource = (value: studioAmbientSensor.rawIlluminance(), name: "Studio Display 光线传感器")
    if ambientProxySourceName != rawAmbientSource.name {
        ambientProxySamples.removeAll()
        ambientProxySourceName = rawAmbientSource.name
        lastLoggedAmbientProxy = nil
        log("环境响应数据源切换为 \(rawAmbientSource.name)")
    }
    let sampleTime = Date()
    if let value = rawAmbientSource.value {
        ambientProxySamples.append((sampleTime, value))
    }
    let sampleCutoff = sampleTime.addingTimeInterval(-10)
    ambientProxySamples.removeAll { $0.0 < sampleCutoff }
    let sortedAmbientValues = ambientProxySamples.map { $0.1 }.sorted()
    let displayAmbientProxy = sortedAmbientValues.isEmpty ? nil : sortedAmbientValues[sortedAmbientValues.count / 2]
    if let displayAmbientProxy, lastLoggedAmbientProxy != displayAmbientProxy {
        log("环境响应分数：\(displayAmbientProxy)（\(rawAmbientSource.name)，10 秒中位数）")
        lastLoggedAmbientProxy = displayAmbientProxy
    }
    statusIndicator.updateDisplayAmbientProxy(displayAmbientProxy, sourceName: rawAmbientSource.name)

    // 熄屏同步是最高优先级：屏幕熄灭期间，环境光、入座检测或灯体自身逻辑
    // 都不得重新点亮灯。持续检测可覆盖灯体在熄屏后中途自行亮起的情况。
    if powerSyncEnabled, isAsleep {
        statusIndicator.suspendPresenceForScreenSleep()
        if lamp.isPowerOn == true {
            let turnedOff = lamp.setPower(on: false)
            helperTurnedLampOff = helperTurnedLampOff || turnedOff
            if turnedOff {
                log("熄屏同步优先级已压制灯体自动重新点亮")
            }
            statusIndicator.update(isAsleep: true, healthy: turnedOff)
        }
    }

    if wasAmbientCloseThreshold != nil, ambientCloseThreshold == nil, ambientTurnedLampOff {
        if !isAsleep { _ = lamp.setPower(on: true) }
        setAmbientLampLock(false)
        statusIndicator.restorePresenceAfterAmbientLock()
        ambientCloseCandidateSince = nil
        log("明亮关灯规则已关闭，已解除关灯锁定并恢复入座检测")
    }
    wasAmbientCloseThreshold = ambientCloseThreshold

    if ambientLinkEnabled != wasAmbientLinkEnabled {
        ambientCloseCandidateSince = nil
        ambientOpenCandidateSince = nil
        if !ambientLinkEnabled, ambientTurnedLampOff {
            if !isAsleep { _ = lamp.setPower(on: true) }
            setAmbientLampLock(false)
            statusIndicator.restorePresenceAfterAmbientLock()
            log("环境联动已关闭，已释放环境关灯状态")
        }
        wasAmbientLinkEnabled = ambientLinkEnabled
    }

    if ambientLinkEnabled, !isAsleep, let displayAmbientProxy {
        if ambientTurnedLampOff {
            statusIndicator.maintainPresenceSuspendedForAmbientLock()
            ambientCloseCandidateSince = nil
            let reachedOpenPoint = statusIndicator.ambientOpenThreshold.map { displayAmbientProxy <= $0 } ?? false
            // 保留用户标定的“昏暗开灯”快速触发；普通变暗则用窄回差和延时恢复。
            // 计时开始后允许短暂波动，只有重新明显高于关灯点才取消，
            // 避免 Studio Display 传感器瞬时跳值让开灯计时永远归零。
            let gradualMargin = statusIndicator.ambientCloseThreshold.map {
                max(8, min(20, Int((Double($0) * 0.04).rounded())))
            }
            let gradualOpenPoint = statusIndicator.ambientCloseThreshold.flatMap { close in
                gradualMargin.map { close - $0 }
            }
            let gradualCancelPoint = statusIndicator.ambientCloseThreshold.flatMap { close in
                gradualMargin.map { close + $0 }
            }
            let reachedGradualOpenPoint = gradualOpenPoint.map { displayAmbientProxy <= $0 } ?? false
            let mayContinueGradualOpening = ambientOpenCandidateSince != nil &&
                (gradualCancelPoint.map { displayAmbientProxy < $0 } ?? false)
            let shouldBeginOpening = reachedOpenPoint || reachedGradualOpenPoint || mayContinueGradualOpening
            if reachedOpenPoint {
                if ambientOpenCandidateSince == nil { ambientOpenCandidateSince = Date() }
                if let since = ambientOpenCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        statusIndicator.restorePresenceAfterAmbientLock()
                        log("环境已低于独立开灯点，已释放环境关灯锁定")
                    }
                } else if lamp.isPowerOn == true {
                    _ = lamp.setPower(on: false)
                }
            } else if shouldBeginOpening {
                if ambientOpenCandidateSince == nil {
                    ambientOpenCandidateSince = Date()
                    if let gradualOpenPoint {
                        log("环境已持续低于平衡回开点 \(gradualOpenPoint)，开始延时确认")
                    }
                }
                if let since = ambientOpenCandidateSince,
                   Date().timeIntervalSince(since) >= 45,
                   statusIndicator.ambientCloseThreshold.map({ displayAmbientProxy < $0 }) == true {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        statusIndicator.restorePresenceAfterAmbientLock()
                        log("环境持续变暗，已平衡恢复 iScreenBar")
                    }
                } else if lamp.isPowerOn == true {
                    _ = lamp.setPower(on: false)
                }
            } else {
                ambientOpenCandidateSince = nil
                if lamp.isPowerOn == true, lamp.setPower(on: false) {
                    log("环境关灯优先级已压制灯体自动重新点亮")
                }
            }
        } else if lamp.isPowerOn == true {
            ambientOpenCandidateSince = nil
            if let closeThreshold = statusIndicator.ambientCloseThreshold,
               displayAmbientProxy >= closeThreshold {
                if ambientCloseCandidateSince == nil { ambientCloseCandidateSince = Date() }
                if let since = ambientCloseCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if statusIndicator.suspendPresenceForAmbientLock(), lamp.setPower(on: false) {
                        setAmbientLampLock(true)
                        ambientCloseCandidateSince = nil
                        log("环境已高于独立关灯点，已关闭 iScreenBar")
                    } else {
                        statusIndicator.restorePresenceAfterAmbientLock()
                    }
                }
            } else {
                ambientCloseCandidateSince = nil
            }
        } else {
            ambientCloseCandidateSince = nil
            if let closeThreshold = statusIndicator.ambientCloseThreshold,
               displayAmbientProxy >= closeThreshold {
                setAmbientLampLock(true)
                ambientOpenCandidateSince = nil
                _ = statusIndicator.suspendPresenceForAmbientLock()
                log("检测到灯已关闭且环境仍高于关灯点，已恢复关灯锁定")
            } else if let openThreshold = statusIndicator.ambientOpenThreshold,
               displayAmbientProxy <= openThreshold {
                if ambientOpenCandidateSince == nil { ambientOpenCandidateSince = Date() }
                if let since = ambientOpenCandidateSince, Date().timeIntervalSince(since) >= 30 {
                    if lamp.setPower(on: true) {
                        setAmbientLampLock(false)
                        ambientOpenCandidateSince = nil
                        log("环境已低于独立开灯点，已开启 iScreenBar")
                    }
                }
            } else {
                ambientOpenCandidateSince = nil
            }
        }
    } else {
        ambientCloseCandidateSince = nil
        ambientOpenCandidateSince = nil
    }

    if powerSyncEnabled != wasPowerSyncEnabled {
        if powerSyncEnabled, isAsleep {
            statusIndicator.suspendPresenceForScreenSleep()
            helperTurnedLampOff = lamp.setPower(on: false)
        } else if !powerSyncEnabled {
            if helperTurnedLampOff { _ = lamp.setPower(on: true) }
            helperTurnedLampOff = false
            statusIndicator.restorePresenceAfterScreenWake()
        }
        wasPowerSyncEnabled = powerSyncEnabled
        statusIndicator.update(isAsleep: isAsleep, healthy: lamp.isConnected && displayID != nil)
    }

    if brightnessFollowEnabled != wasBrightnessFollowEnabled {
        brightnessOffset = nil
        lastDisplayBrightness = nil
        if brightnessFollowEnabled {
            anchorStatusRevision = lamp.statusRevision
            lamp.requestStatus()
        } else {
            anchorStatusRevision = nil
        }
        wasBrightnessFollowEnabled = brightnessFollowEnabled
        statusIndicator.update(isAsleep: isAsleep, healthy: lamp.isConnected && displayID != nil)
    }

    if isAsleep != wasAsleep {
        if isAsleep {
            log("检测到 Studio Display 熄屏")
            if powerSyncEnabled {
                statusIndicator.suspendPresenceForScreenSleep()
                helperTurnedLampOff = lamp.setPower(on: false)
                statusIndicator.update(isAsleep: true, healthy: helperTurnedLampOff)
            } else {
                statusIndicator.update(isAsleep: true, healthy: lamp.isConnected && displayID != nil)
            }
        } else {
            log("检测到 Studio Display 唤醒")
            if helperTurnedLampOff, !ambientTurnedLampOff {
                let restored = lamp.setPower(on: true)
                statusIndicator.update(isAsleep: false, healthy: restored)
                helperTurnedLampOff = false
            } else {
                helperTurnedLampOff = false
                statusIndicator.update(isAsleep: false, healthy: lamp.isConnected && displayID != nil)
            }
            statusIndicator.restorePresenceAfterScreenWake()
        }
        wasAsleep = isAsleep
    }

    statusIndicator.applyScheduledTemperatureIfNeeded(isAsleep: isAsleep)

    if brightnessFollowEnabled, !isAsleep, let displayID,
       let displayBrightness = displayBrightnessReader.percent(for: displayID) {
        if let anchorRevision = anchorStatusRevision,
           lamp.statusRevision > anchorRevision,
           let lampBrightness = lamp.currentBrightness {
            if lamp.isAutoLightEnabled == true {
                log("检测到灯具自动感光仍在运行；亮度跟随将在关闭自动感光后生效")
                brightnessOffset = nil
                lastDisplayBrightness = displayBrightness
            } else {
                brightnessOffset = lampBrightness - displayBrightness
                lastDisplayBrightness = displayBrightness
                log("已锁定亮度差：iScreenBar \(lampBrightness)% / Studio Display \(displayBrightness)%")
            }
            anchorStatusRevision = nil
        } else if let brightnessOffset, displayBrightness != lastDisplayBrightness {
            let target = max(1, min(100, displayBrightness + brightnessOffset))
            if lamp.setBrightness(target) {
                lastDisplayBrightness = displayBrightness
            }
        }
    }

    if Date().timeIntervalSince(lastStatusRequest) >= 2 {
        let connected = lamp.checkConnection()
        if connected != wasLampConnected {
            if connected {
                log("检测到 iScreenBar 已恢复连接，正在恢复同步状态")
                if powerSyncEnabled {
                    if isAsleep {
                        helperTurnedLampOff = lamp.setPower(on: false)
                    } else if !ambientTurnedLampOff {
                        _ = lamp.setPower(on: true)
                    }
                }
                if brightnessFollowEnabled {
                    brightnessOffset = nil
                    lastDisplayBrightness = nil
                    anchorStatusRevision = lamp.statusRevision
                    lamp.requestStatus()
                }
            } else {
                log("检测到 iScreenBar 已断开")
                brightnessOffset = nil
                anchorStatusRevision = nil
            }
            wasLampConnected = connected
        }
        statusIndicator.update(isAsleep: isAsleep, healthy: connected && displayID != nil)
        lastStatusRequest = Date()
    }
}

// 加入 common 模式，菜单展开时同步仍持续进行。
let pollingTimer = Timer(timeInterval: pollInterval, repeats: true) { _ in
    pollDisplayAndLamp()
}
pollingTimer.tolerance = 0.05
RunLoop.main.add(pollingTimer, forMode: .common)
pollDisplayAndLamp()
NSApplication.shared.run()
