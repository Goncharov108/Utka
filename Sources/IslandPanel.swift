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
}

/// Тёмная подложка островка.
final class IslandRoot: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Островок у верхнего края выбранного экрана.
final class IslandPanel {
    let window: KeyPanel
    private let titleLabel = UtkaChrome.label("Полка", size: 15, weight: .semibold)
    private let body = NSView()
    private let buttons: [NSButton]
    private let sections: [NSView]
    private var current: IslandSection = .shelf
    var onSection: ((IslandSection) -> Void)?

    init(shelf: NSView, clipboard: NSView, presets: NSView, translator: NSView, mark: NSImage?) {
        sections = [shelf, clipboard, presets, translator]
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Утка"
        panel.identifier = NSUserInterfaceItemIdentifier("utka.island")
        panel.isFloatingPanel = true
        panel.level = .statusBar
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
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        panel.contentView = root

        let rail = NSView()
        let markView = NSImageView()
        markView.image = mark
        markView.imageScaling = .scaleProportionallyUpOrDown
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
            rail.frame = NSRect(x: 0, y: 0, width: 58, height: root.bounds.height)
            markView.frame = NSRect(x: 13, y: root.bounds.height - 46, width: 32, height: 32)
            var y = root.bounds.height - 92
            for button in made {
                button.frame = NSRect(x: 11, y: y, width: 36, height: 36)
                y -= 42
            }
            self.titleLabel.frame = NSRect(x: 74, y: root.bounds.height - 36, width: root.bounds.width - 90, height: 22)
            self.body.frame = NSRect(x: 70, y: 12, width: root.bounds.width - 82, height: root.bounds.height - 52)
            if let visible = self.body.subviews.first {
                visible.frame = self.body.bounds
            }
        }
    }

    func bindActions(target: AnyObject, action: Selector) {
        for button in buttons {
            button.target = target
            button.action = action
        }
    }

    func show(on screen: NSScreen) {
        let frame = frame(on: screen)
        if window.isVisible && roughly(window.frame, frame) { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame.offsetBy(dx: 0, dy: 8), display: false)
        window.alphaValue = 0
        if !window.isVisible { window.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0 : 0.18
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }

    func hide() {
        guard window.isVisible else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduce ? 0 : 0.15
            window.animator().alphaValue = 0
        }, completionHandler: { [weak window] in
            window?.orderOut(nil)
            window?.alphaValue = 1
        })
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
        let width = min(600, limit.width)
        let height = min(340, limit.height)
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func roughly(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
