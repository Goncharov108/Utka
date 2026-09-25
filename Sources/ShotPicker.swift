import AppKit

/// Окно выбора области: прозрачное, но принимает мышь и Escape.
private final class ShotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Затемнение одного экрана и рамка выделения.
private final class ShotShade: NSView {
    var onRelease: ((CGRect) -> Void)?
    private var anchor: NSPoint?
    private let band = NSView()

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        band.wantsLayer = true
        band.layer?.borderColor = NSColor.white.cgColor
        band.layer?.borderWidth = 1.5
        band.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        if band.superview == nil { addSubview(band) }
        band.frame = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        band.frame = Self.box(anchor, convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor, let window else { return }
        let local = Self.box(anchor, convert(event.locationInWindow, from: nil))
        self.anchor = nil
        guard local.width > 2, local.height > 2 else {
            onRelease?(.null)
            return
        }
        onRelease?(window.convertToScreen(local))
    }

    /// Прямоугольник между двумя точками, сторона не отрицательная.
    private static func box(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}

/// Свой выбор области: системный Cmd+Shift+4 из процесса утки не стартует.
final class ShotPicker {
    var onDone: (() -> Void)?
    private var windows: [NSWindow] = []
    private var escapeMonitor: Any?
    private var busy = false

    func begin() {
        guard windows.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let window = ShotWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let shade = ShotShade(frame: NSRect(origin: .zero, size: screen.frame.size))
            shade.onRelease = { [weak self] rect in self?.finish(rect) }
            window.contentView = shade
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            if screen.frame.contains(mouse) { window.makeKey() }
            windows.append(window)
        }
        NSCursor.crosshair.push()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(.null)
            return nil
        }
    }

    /// Прячет рамку и пишет файл. Пустой прямоугольник — отмена.
    private func finish(_ rect: CGRect) {
        guard !busy else { return }
        busy = true
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        NSCursor.pop()
        guard rect.width > 2, rect.height > 2 else {
            busy = false
            onDone?()
            return
        }
        let captured = rect
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.write(captured)
            DispatchQueue.main.async {
                self?.busy = false
                self?.onDone?()
            }
        }
    }

    /// screencapture -R: ноль сверху слева основного экрана, не снизу как у AppKit.
    private static func write(_ appKit: CGRect) {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens[0]
        let top = primary.frame.height - appKit.origin.y - appKit.height
        let arg = String(format: "%.0f,%.0f,%.0f,%.0f", appKit.origin.x, top, appKit.width, appKit.height)
        let dir = UtkaPaths.support.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Self.stamp.string(from: Date())
        let dest = dir.appendingPathComponent("Снимок экрана \(stamp).png")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-R", arg, dest.path]
        if (try? task.run()) != nil { task.waitUntilExit() }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        return formatter
    }()
}
