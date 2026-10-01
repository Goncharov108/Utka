import AppKit

/// Плавная перестановка: тащимая карточка едет за курсором, остальные догоняют слоты.
final class DragStrip {
    var drag: NSView?
    var settling: NSView?
    var dragOrigin = NSPoint.zero
    private var lift: CGFloat = 0
    private var liftTarget: CGFloat = 0
    private var shown: [ObjectIdentifier: NSPoint] = [:]
    private var home: [ObjectIdentifier: NSPoint] = [:]

    var traveling: Bool { drag != nil || settling != nil }

    func begin(_ view: NSView) {
        drag = view
        settling = nil
        liftTarget = 1
    }

    /// Отпускание: строка доезжает в свой слот, а не прыгает.
    func end() {
        if let drag {
            shown[ObjectIdentifier(drag)] = dragOrigin
            settling = drag
        }
        drag = nil
        liftTarget = 0
    }

    func reset() {
        drag = nil
        settling = nil
        lift = 0
        liftTarget = 0
        shown.removeAll()
        home.removeAll()
    }

    func finish() {
        settling = nil
        lift = 0
        liftTarget = 0
    }

    /// Кладёт вид в слот или оставляет за курсором.
    func place(_ view: NSView, home homePoint: NSPoint, size: NSSize) {
        let id = ObjectIdentifier(view)
        home[id] = homePoint
        let point: NSPoint
        if view === drag {
            point = dragOrigin
        } else if traveling, let current = shown[id] {
            point = current
        } else {
            point = homePoint
        }
        shown[id] = point
        let raised = view === drag || view === settling
        let extra = raised ? 2 * lift : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = NSRect(
            x: point.x - extra,
            y: point.y - extra,
            width: size.width + extra * 2,
            height: size.height + extra * 2
        )
        CATransaction.commit()
        utkaLift(view, raised ? lift : 0)
    }

    /// Сдвигает лежащие карточки к слотам. true, пока кадр ещё едет.
    func step() -> Bool {
        var moving = false
        if abs(lift - liftTarget) > 0.01 {
            lift += (liftTarget - lift) * 0.22
            moving = true
        } else {
            lift = liftTarget
        }
        let held = drag.map(ObjectIdentifier.init)
        for (id, slot) in home {
            if id == held { continue }
            guard var current = shown[id] else { continue }
            let dx = slot.x - current.x
            let dy = slot.y - current.y
            if abs(dx) > 0.4 || abs(dy) > 0.4 {
                current.x += dx * 0.22
                current.y += dy * 0.22
                shown[id] = current
                moving = true
            } else {
                shown[id] = slot
            }
        }
        return moving
    }
}

/// Сетка карточек файлов с вертикальной прокруткой. Внутри островка карточки переставляются,
/// за краем островка файл уходит наружу. Общая для полки и закреп.
final class FileGridView: NSView {
    /// Держать островок открытым, пока карточку тащат.
    var onHold: ((Bool) -> Void)?
    /// Новое место карточки среди файлов.
    var onPlace: ((String, Int) -> Void)?
    /// Перестановка доехала. Отложенная пересборка может идти.
    var onSettled: (() -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let strip = DragStrip()
    private let cardSize: NSSize
    private let gap: CGFloat = 12
    private var cards: [FileCardView] = []
    private var ids: [ObjectIdentifier: String] = [:]
    private var motionTimer: Timer?
    private var held = false

    var isEmpty: Bool { cards.isEmpty }
    var isDragging: Bool { strip.drag != nil }

    init(cardSize: NSSize) {
        self.cardSize = cardSize
        super.init(frame: .zero)
        scroll.contentView = FlippedClipView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    /// Новый набор карточек. Перестановку и порядок подключает сама сетка.
    func setCards(_ items: [(id: String, card: FileCardView)]) {
        strip.reset()
        document.subviews.forEach { $0.removeFromSuperview() }
        ids.removeAll()
        cards = items.map { item in
            let card = item.card
            ids[ObjectIdentifier(card)] = item.id
            card.canReorder = true
            card.onReorderDrag = { [weak self, weak card] origin in
                guard let self, let card else { return }
                self.drag(card, to: origin)
            }
            card.onReorderDrop = { [weak self] in self?.drop() }
            document.addSubview(card)
            return card
        }
        layoutGrid()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scroll.frame = bounds
        layoutGrid()
    }

    private struct Grid {
        var width: CGFloat
        var per: Int
        var stepX: CGFloat
        var stepY: CGFloat
    }

    /// Ширина прокрутки и сколько карточек встаёт в ряд.
    private func grid() -> Grid {
        let width = max(scroll.contentView.bounds.width, scroll.bounds.width, 1)
        let per = max(1, Int((width + gap) / (cardSize.width + gap)))
        return Grid(width: width, per: per, stepX: cardSize.width + gap, stepY: cardSize.height + gap)
    }

    /// Левый верх слота в документе, ноль сверху.
    private func slot(_ index: Int, _ grid: Grid) -> NSPoint {
        NSPoint(x: CGFloat(index % grid.per) * grid.stepX, y: CGFloat(index / grid.per) * grid.stepY)
    }

    private func layoutGrid() {
        let grid = grid()
        for (index, card) in cards.enumerated() {
            strip.place(card, home: slot(index, grid), size: cardSize)
        }
        let rows = cards.isEmpty ? 0 : Int(ceil(Double(cards.count) / Double(grid.per)))
        let height = CGFloat(rows) * grid.stepY
        document.frame = NSRect(x: 0, y: 0, width: grid.width, height: max(height, scroll.contentView.bounds.height))
        if let top = strip.drag ?? strip.settling {
            document.addSubview(top, positioned: .above, relativeTo: nil)
        }
    }

    /// Тащит карточку по сетке и ставит в слот, куда попал её центр.
    private func drag(_ card: FileCardView, to origin: NSPoint) {
        if strip.drag == nil {
            strip.begin(card)
            hold(true)
        }
        let grid = grid()
        let rows = Int(ceil(Double(max(cards.count, 1)) / Double(grid.per)))
        let clamped = NSPoint(
            x: min(max(0, origin.x), CGFloat(max(0, grid.per - 1)) * grid.stepX),
            y: min(max(0, origin.y), CGFloat(max(0, rows - 1)) * grid.stepY)
        )
        strip.dragOrigin = clamped
        let col = min(max(0, Int((clamped.x / grid.stepX).rounded())), grid.per - 1)
        let row = max(0, Int((clamped.y / grid.stepY).rounded()))
        let target = min(row * grid.per + col, cards.count - 1)
        if let from = cards.firstIndex(where: { $0 === card }), from != target, let id = ids[ObjectIdentifier(card)] {
            cards.remove(at: from)
            cards.insert(card, at: target)
            onPlace?(id, target)
        }
        kickMotion()
        layoutGrid()
        card.scrollToVisible(card.bounds)
    }

    private func drop() {
        strip.end()
        hold(false)
        kickMotion()
        layoutGrid()
    }

    private func hold(_ on: Bool) {
        guard held != on else { return }
        held = on
        onHold?(on)
    }

    /// Кадры сами: у фонового приложения системный аниматор не тикает.
    private func kickMotion() {
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.stepMotion(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion(_ timer: Timer) {
        let moving = strip.step()
        layoutGrid()
        guard !moving else { return }
        strip.finish()
        timer.invalidate()
        motionTimer = nil
        layoutGrid()
        onSettled?()
    }
}
