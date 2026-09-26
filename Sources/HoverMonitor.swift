import AppKit

/// Следит за курсором и открывает островок у верхнего центра любого экрана.
final class HoverMonitor {
    var enabled = true
    var suspended = false
    var extraHitRect: () -> CGRect? = { nil }
    var onHot: ((NSScreen) -> Void)?
    var onCold: (() -> Void)?

    private var timer: Timer?
    private var insideSince: Date?
    private var outsideSince: Date?
    private var open = false
    private var activeFrame: CGRect?

    /// Полоса по центру верхнего края. Не захватывает меню Apple и часы.
    static func zone(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let height: CGFloat = 120
        let width = min(max(screen.frame.width * 0.45, 480), 900)
        // contains() не включает верхнюю границу, поэтому самый край экрана в зону не попадал.
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height + 4)
    }

    /// Окно уже убрано с экрана. Иначе курсор у верхнего края не откроет его снова.
    func markClosed() {
        open = false
        insideSince = nil
        outsideSince = nil
        activeFrame = nil
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        if !enabled {
            insideSince = nil
            outsideSince = nil
            if open {
                open = false
                activeFrame = nil
                onCold?()
            }
            return
        }
        if suspended {
            insideSince = nil
            return
        }
        if let screen = screen(at: point) {
            outsideSince = nil
            if open {
                if !sameFrame(activeFrame, screen.frame) {
                    activeFrame = screen.frame
                    onHot?(screen)
                }
                return
            }
            if insideSince == nil { insideSince = Date() }
            if let since = insideSince, Date().timeIntervalSince(since) >= 0.2 {
                open = true
                insideSince = nil
                activeFrame = screen.frame
                onHot?(screen)
            }
            return
        }
        insideSince = nil
        if let extra = extraHitRect(), extra.contains(point), open {
            outsideSince = nil
            return
        }
        if suspended && open {
            outsideSince = nil
            return
        }
        guard open else {
            outsideSince = nil
            return
        }
        if outsideSince == nil { outsideSince = Date() }
        if let since = outsideSince, Date().timeIntervalSince(since) >= 0.9 {
            open = false
            outsideSince = nil
            activeFrame = nil
            onCold?()
        }
    }

    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { Self.zone(for: $0).contains(point) }
    }

    private func sameFrame(_ stored: CGRect?, _ frame: CGRect) -> Bool {
        guard let stored else { return false }
        return abs(stored.minX - frame.minX) < 1 && abs(stored.minY - frame.minY) < 1
            && abs(stored.width - frame.width) < 1 && abs(stored.height - frame.height) < 1
    }
}
