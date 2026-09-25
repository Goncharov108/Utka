import AppKit

enum IslandSection: Int, CaseIterable {
    case shelf, clipboard, presets, translate

    var title: String {
        switch self {
        case .shelf: return "Полка"
        case .clipboard: return "Буфер"
        case .presets: return "Заготовки"
        case .translate: return "Перевод"
        }
    }

    var symbol: String {
        switch self {
        case .shelf: return "square.stack.3d.up"
        case .clipboard: return "doc.on.clipboard"
        case .presets: return "pin"
        case .translate: return "character.book.closed"
        }
    }
}

/// Панель без рамки, которая может принять фокус для полей текста.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// Правка без меню «Правка». Код клавиши, не буква: на русской раскладке Cmd+A иначе пищит.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performEditShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func performEditShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        guard let text = firstResponder as? NSTextView else { return false }
        switch event.keyCode {
        case 0:
            text.selectAll(nil)
        case 8:
            text.copy(nil)
        case 7:
            text.cut(nil)
        case 9:
            text.paste(nil)
        case 6:
            if flags.contains(.shift) {
                text.undoManager?.redo()
            } else {
                text.undoManager?.undo()
            }
        default:
            return false
        }
        return true
    }
}

/// Чёрная капля: верхние углы выпуклые, плашка шире книзу и держится за кромку.
final class IslandRoot: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.path = islandSilhouette(bounds: bounds, radius: 36)
        mask.contentsScale = window?.backingScaleFactor ?? 2
        layer?.mask = mask
    }

    /// Уши на всю кромку, плечо вогнуто внутрь, низ скруглён.
    private func islandSilhouette(bounds: CGRect, radius: CGFloat) -> CGPath {
        let width = bounds.width
        let height = bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: width, y: height))
        path.addArc(
            center: CGPoint(x: width, y: height - radius),
            radius: radius,
            startAngle: .pi / 2,
            endAngle: .pi,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: width - radius, y: radius))
        path.addArc(
            center: CGPoint(x: width - radius * 2, y: radius),
            radius: radius,
            startAngle: 0,
            endAngle: -.pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: radius * 2, y: 0))
        path.addArc(
            center: CGPoint(x: radius * 2, y: radius),
            radius: radius,
            startAngle: -.pi / 2,
            endAngle: .pi,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: radius, y: height - radius))
        path.addArc(
            center: CGPoint(x: 0, y: height - radius),
            radius: radius,
            startAngle: 0,
            endAngle: .pi / 2,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// Островок у верхнего края выбранного экрана.
final class IslandPanel {
    let window: KeyPanel
    private let titleLabel = UtkaChrome.label("Полка", size: 15, weight: .semibold)
    private let body = NSView()
    private let buttons: [NSButton]
    private let sections: [NSView]
    private var current: IslandSection = .shelf
    private var slideTimer: Timer?
    private var slideFrom: CGRect = .zero
    private var slideTo: CGRect = .zero
    private var slideStart: Date?
    private var slideOrderOut = false
    var onSection: ((IslandSection) -> Void)?

    init(shelf: NSView, clipboard: NSView, presets: NSView, translator: NSView, mark: NSImage?) {
        sections = [shelf, clipboard, presets, translator]
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Утка"
        panel.identifier = NSUserInterfaceItemIdentifier("utka.island")
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        window = panel

        let root = IslandRoot()
        root.wantsLayer = true
        panel.contentView = root

        let rail = NSView()
        let markView = DuckMarkView()
        markView.image = mark.map { MenuMark.cutout(from: $0) }
        rail.addSubview(markView)

        var made: [NSButton] = []
        for section in IslandSection.allCases {
            let button = NSButton()
            button.isBordered = false
            button.bezelStyle = .shadowlessSquare
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.toolTip = section.title
            button.tag = section.rawValue
            button.target = nil
            rail.addSubview(button)
            made.append(button)
        }
        buttons = made

        root.addSubview(rail)
        root.addSubview(titleLabel)
        root.addSubview(body)
        showSection(.shelf)

        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: root, queue: .main) { _ in
            rail.frame = NSRect(x: 0, y: 0, width: 88, height: root.bounds.height)
            markView.frame = NSRect(x: 44, y: root.bounds.height - 86, width: 40, height: 40)
            var y = root.bounds.height - 132
            for button in made {
                button.frame = NSRect(x: 46, y: y, width: 36, height: 36)
                y -= 42
            }
            self.titleLabel.frame = NSRect(x: 96, y: root.bounds.height - 36, width: root.bounds.width - 112, height: 22)
            self.body.frame = NSRect(x: 96, y: 12, width: root.bounds.width - 108, height: root.bounds.height - 52)
            if let visible = self.body.subviews.first {
                visible.frame = self.body.bounds
                visible.resizeSubviews(withOldSize: visible.bounds.size)
            }
        }
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: root)
    }

    func bindActions(target: AnyObject, action: Selector) {
        for button in buttons {
            button.target = target
            button.action = action
        }
    }

    func show(on screen: NSScreen) {
        let target = frame(on: screen)
        if window.isVisible && roughly(window.frame, target) && slideTimer == nil { return }
        let tucked = CGRect(x: target.minX, y: screen.frame.maxY, width: target.width, height: target.height)
        window.alphaValue = 1
        if !window.isVisible {
            window.setFrame(tucked, display: false)
            window.orderFrontRegardless()
        }
        slide(from: window.frame, to: target, orderOut: false)
    }

    func hide() {
        guard window.isVisible else { return }
        let frame = window.frame
        let top = (window.screen ?? NSScreen.main)?.frame.maxY ?? frame.maxY
        let tucked = CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height)
        slide(from: frame, to: tucked, orderOut: true)
    }

    /// Выезд из-за кромки. Аниматор окна у неактивного агента не тикает, поэтому кадры сами.
    private func slide(from: CGRect, to: CGRect, orderOut: Bool) {
        slideTimer?.invalidate()
        slideFrom = from
        slideTo = to
        slideStart = Date()
        slideOrderOut = orderOut
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.stepSlide(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func stepSlide(_ timer: Timer) {
        let duration = 0.42
        let elapsed = Date().timeIntervalSince(slideStart ?? Date())
        let progress = min(1, elapsed / duration)
        let eased = 1 - pow(1 - progress, 3)
        let frame = CGRect(
            x: slideFrom.minX + (slideTo.minX - slideFrom.minX) * eased,
            y: slideFrom.minY + (slideTo.minY - slideFrom.minY) * eased,
            width: slideFrom.width + (slideTo.width - slideFrom.width) * eased,
            height: slideFrom.height + (slideTo.height - slideFrom.height) * eased
        )
        window.setFrame(frame, display: true)
        if progress >= 1 {
            timer.invalidate()
            slideTimer = nil
            if slideOrderOut { window.orderOut(nil) }
        }
    }

    func select(_ section: IslandSection) {
        showSection(section)
        onSection?(section)
    }

    private func showSection(_ section: IslandSection) {
        current = section
        titleLabel.stringValue = section.title
        body.subviews.forEach { $0.removeFromSuperview() }
        let view = sections[section.rawValue]
        view.frame = body.bounds
        view.autoresizingMask = [.width, .height]
        body.addSubview(view)
        for button in buttons {
            let on = button.tag == section.rawValue
            button.contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.4)
        }
    }

    private func frame(on screen: NSScreen) -> CGRect {
        let limit = screen.frame.insetBy(dx: 8, dy: 8)
        let width = min(720, limit.width)
        let height = min(280, limit.height)
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func roughly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
