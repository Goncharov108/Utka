import AppKit
import ImageIO

/// Точка пометки в пикселях картинки, сверху вниз.
struct ShotPoint: Codable, Equatable {
    var x: Double
    var y: Double

    var point: CGPoint { CGPoint(x: x, y: y) }

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

/// Цвет пометки. Старые файлы без цвета читаются как белые.
struct ShotInk: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    static let white = ShotInk(red: 1, green: 1, blue: 1)
    static let palette: [ShotInk] = [
        ShotInk(red: 1, green: 1, blue: 1),
        ShotInk(red: 0.12, green: 0.12, blue: 0.12),
        ShotInk(red: 0.93, green: 0.24, blue: 0.18),
        ShotInk(red: 0.98, green: 0.76, blue: 0.14),
        ShotInk(red: 0.24, green: 0.74, blue: 0.38),
        ShotInk(red: 0.22, green: 0.48, blue: 0.95)
    ]

    static func nearest(_ ink: ShotInk) -> Int {
        palette.enumerated().min { lhs, rhs in
            distance(lhs.element, ink) < distance(rhs.element, ink)
        }?.offset ?? 0
    }

    private static func distance(_ a: ShotInk, _ b: ShotInk) -> Double {
        let dr = a.red - b.red
        let dg = a.green - b.green
        let db = a.blue - b.blue
        return dr * dr + dg * dg + db * db
    }
}

/// Одна пометка поверх снимка. В файл пикселей попадает только при сохранении.
struct ShotMark: Codable, Equatable {
    var id: String
    var kind: String
    var points: [ShotPoint]
    var text: String
    var textSize: Double
    var red: Double
    var green: Double
    var blue: Double

    var ink: ShotInk {
        get { ShotInk(red: red, green: green, blue: blue) }
        set {
            red = newValue.red
            green = newValue.green
            blue = newValue.blue
        }
    }

    init(id: String, kind: String, points: [ShotPoint], text: String, textSize: Double, ink: ShotInk) {
        self.id = id
        self.kind = kind
        self.points = points
        self.text = text
        self.textSize = textSize
        red = ink.red
        green = ink.green
        blue = ink.blue
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(String.self, forKey: .id)
        kind = try box.decode(String.self, forKey: .kind)
        points = try box.decode([ShotPoint].self, forKey: .points)
        text = try box.decodeIfPresent(String.self, forKey: .text) ?? ""
        textSize = try box.decodeIfPresent(Double.self, forKey: .textSize) ?? 18
        red = try box.decodeIfPresent(Double.self, forKey: .red) ?? 1
        green = try box.decodeIfPresent(Double.self, forKey: .green) ?? 1
        blue = try box.decodeIfPresent(Double.self, forKey: .blue) ?? 1
    }
}

enum ShotTool: Int {
    case select, line, arrow, rect, pencil, text
}

/// Скрытые соседи PNG: чистые пиксели и пометки. Имена с точкой полка не подхватывает.
enum ShotStore {
    static func discard(beside path: String) {
        let image = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: baseURL(for: image))
        try? FileManager.default.removeItem(at: marksURL(for: image))
    }

    /// Чистая картинка и пометки. Без базы пометки не читаем: иначе они легли бы вторым слоем.
    static func load(url: URL) -> (image: CGImage, marks: [ShotMark])? {
        let base = baseURL(for: url)
        let hasBase = FileManager.default.fileExists(atPath: base.path)
        guard let image = readImage(hasBase ? base : url) else { return nil }
        guard hasBase, let data = try? Data(contentsOf: marksURL(for: url)) else {
            return (image, [])
        }
        let marks = (try? JSONDecoder().decode([ShotMark].self, from: data)) ?? []
        return (image, marks)
    }

    static func writeImage(_ image: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func writeMarks(_ marks: [ShotMark], beside url: URL) {
        guard let data = try? JSONEncoder().encode(marks) else { return }
        try? data.write(to: marksURL(for: url), options: .atomic)
    }

    static func baseURL(for image: URL) -> URL {
        hidden(image, ".base.png")
    }

    private static func marksURL(for image: URL) -> URL {
        hidden(image, ".marks.json")
    }

    private static func hidden(_ image: URL, _ suffix: String) -> URL {
        image.deletingLastPathComponent().appendingPathComponent("." + image.lastPathComponent + suffix)
    }

    /// Полные пиксели файла, без уменьшенной копии.
    static func readImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary)
    }
}

/// Рисует снимок и пометки в прямоугольнике. Координаты пометок — пиксели картинки, сверху вниз.
func drawShot(image: NSImage, imageSize: CGSize, marks: [ShotMark], in rect: CGRect, selected: String?) {
    let screen = NSGraphicsContext.current?.cgContext.convertToDeviceSpace(CGSize(width: 1, height: 1)).width ?? 2
    let shrinking = rect.width * screen + 0.5 < imageSize.width
    NSGraphicsContext.current?.imageInterpolation = shrinking ? .high : .none
    drawImageUpright(image, in: rect)
    drawMarks(marks, imageSize: imageSize, in: rect, selected: selected)
}

/// В перевёрнутом окне обычный draw кладёт картинку вверх ногами. Здесь верх остаётся сверху.
func drawImageUpright(_ image: NSImage, in rect: NSRect) {
    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    if ctx.isFlipped {
        let undo = NSAffineTransform()
        undo.translateX(by: rect.midX, yBy: rect.midY)
        undo.scaleX(by: 1, yBy: -1)
        undo.translateX(by: -rect.midX, yBy: -rect.midY)
        undo.concat()
    }
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGraphicsState()
}

/// Только пометки. Контекст уже с осью игрек сверху вниз.
func drawMarks(_ marks: [ShotMark], imageSize: CGSize, in rect: CGRect, selected: String?) {
    let scale = rect.width / max(imageSize.width, 1)
    let width = max(1.25, imageSize.width * 0.003) * scale
    for mark in marks {
        let strong = mark.id == selected
        let ink = mark.ink.color
        strokeMark(path(for: mark, in: rect, imageSize: imageSize), width: strong ? width * 1.45 : width, color: ink)
        if mark.kind == "text", let origin = mark.points.first {
            let font = UtkaChrome.font(max(11, CGFloat(mark.textSize) * scale))
            let shadow = NSShadow()
            shadow.shadowColor = markHalo(ink)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = .zero
            let placed = place(origin, in: rect, imageSize: imageSize)
            let box = NSRect(x: placed.x, y: placed.y, width: max(rect.width, 40), height: font.pointSize * 1.4)
            (mark.text as NSString).draw(in: box, withAttributes: [
                .font: font,
                .foregroundColor: ink,
                .shadow: shadow
            ])
        }
    }
}

/// Снимок с впечатанными пометками. Картинка остаётся как была, пометки сверху вниз.
func flattenShot(image: CGImage, marks: [ShotMark]) -> Data? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0, let rep = bitmap(width, height) else { return nil }
    let size = NSSize(width: width, height: height)
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let cg = NSGraphicsContext.current?.cgContext
    cg?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    cg?.translateBy(x: 0, y: CGFloat(height))
    cg?.scaleBy(x: 1, y: -1)
    drawMarks(marks, imageSize: size, in: NSRect(origin: .zero, size: size), selected: nil)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

private func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
}

private func place(_ point: ShotPoint, in rect: CGRect, imageSize: CGSize) -> CGPoint {
    CGPoint(
        x: rect.minX + CGFloat(point.x) / max(imageSize.width, 1) * rect.width,
        y: rect.minY + CGFloat(point.y) / max(imageSize.height, 1) * rect.height
    )
}

private func path(for mark: ShotMark, in rect: CGRect, imageSize: CGSize) -> NSBezierPath {
    let spots = mark.points.map { place($0, in: rect, imageSize: imageSize) }
    let path = NSBezierPath()
    switch mark.kind {
    case "line", "arrow":
        guard spots.count >= 2 else { return path }
        path.move(to: spots[0])
        path.line(to: spots[1])
        if mark.kind == "arrow" {
            let scale = rect.width / max(imageSize.width, 1)
            let length = max(10, imageSize.width * 0.012) * scale
            let (left, right) = arrowHead(from: spots[0], to: spots[1], length: length)
            path.move(to: left)
            path.line(to: spots[1])
            path.line(to: right)
        }
    case "rect":
        guard spots.count >= 2 else { return path }
        let box = NSRect(
            x: min(spots[0].x, spots[1].x),
            y: min(spots[0].y, spots[1].y),
            width: abs(spots[1].x - spots[0].x),
            height: abs(spots[1].y - spots[0].y)
        )
        path.appendRect(box)
    case "pencil":
        guard let first = spots.first else { return path }
        path.move(to: first)
        for spot in spots.dropFirst() { path.line(to: spot) }
    default:
        break
    }
    return path
}

private func strokeMark(_ path: NSBezierPath, width: CGFloat, color: NSColor) {
    guard !path.isEmpty else { return }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = width + max(1.5, width * 0.45)
    markHalo(color).setStroke()
    path.stroke()
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

/// Тёмная пометка получает светлый контур, светлая — тёмный, чтобы её было видно на снимке.
private func markHalo(_ color: NSColor) -> NSColor {
    let rgb = color.usingColorSpace(.sRGB) ?? color
    let luma = 0.3 * rgb.redComponent + 0.59 * rgb.greenComponent + 0.11 * rgb.blueComponent
    if luma < 0.4 { return NSColor.white.withAlphaComponent(0.9) }
    return NSColor.black.withAlphaComponent(0.85)
}

private func arrowHead(from: CGPoint, to: CGPoint, length: CGFloat) -> (CGPoint, CGPoint) {
    let angle = atan2(to.y - from.y, to.x - from.x)
    let spread = CGFloat.pi / 7
    let left = CGPoint(x: to.x - length * cos(angle - spread), y: to.y - length * sin(angle - spread))
    let right = CGPoint(x: to.x - length * cos(angle + spread), y: to.y - length * sin(angle + spread))
    return (left, right)
}

private func segmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let length = dx * dx + dy * dy
    if length < 0.01 { return hypot(point.x - start.x, point.y - start.y) }
    let t = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
    return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
}

/// Попадает ли точка в пометку. slop — допуск в пикселях картинки.
func shotMarkHit(_ mark: ShotMark, point: CGPoint, slop: CGFloat) -> Bool {
    let spots = mark.points.map(\.point)
    switch mark.kind {
    case "line", "arrow":
        guard spots.count >= 2 else { return false }
        return segmentDistance(point, spots[0], spots[1]) <= slop
    case "rect":
        guard spots.count >= 2 else { return false }
        let box = CGRect(
            x: min(spots[0].x, spots[1].x) - slop,
            y: min(spots[0].y, spots[1].y) - slop,
            width: abs(spots[1].x - spots[0].x) + slop * 2,
            height: abs(spots[1].y - spots[0].y) + slop * 2
        )
        return box.contains(point)
    case "pencil":
        guard spots.count >= 2 else { return false }
        for index in 1..<spots.count where segmentDistance(point, spots[index - 1], spots[index]) <= slop {
            return true
        }
        return false
    case "text":
        guard let origin = spots.first else { return false }
        let width = max(24, CGFloat(mark.text.count) * CGFloat(mark.textSize) * 0.55)
        let height = CGFloat(mark.textSize) * 1.4
        let box = CGRect(x: origin.x - slop, y: origin.y - slop, width: width + slop * 2, height: height + slop * 2)
        return box.contains(point)
    default:
        return false
    }
}

/// Поле снимка: картинка вписана, пометки рисуются поверх.
final class ShotCanvasView: NSView, NSTextFieldDelegate {
    var image: NSImage?
    var imageSize: CGSize = .zero
    private(set) var marks: [ShotMark] = []
    var tool: ShotTool = .select { didSet { needsDisplay = true } }
    var ink = ShotInk.white
    var fontStep = 1
    var onStyle: ((ShotInk, Double) -> Void)?

    private var selectedID: String?
    private var draft: ShotMark?
    private var history: [[ShotMark]] = []
    private var dragOrigin: CGPoint?
    private var dragOriginal: ShotMark?
    private var dragPushed = false
    private var textField: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setMarks(_ marks: [ShotMark]) {
        self.marks = marks
        needsDisplay = true
    }

    func undo() {
        guard let previous = history.popLast() else { return }
        marks = previous
        selectedID = nil
        draft = nil
        needsDisplay = true
    }

    func deleteSelection() {
        guard let selectedID else { return }
        pushUndo()
        marks.removeAll { $0.id == selectedID }
        self.selectedID = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1).setFill()
        bounds.fill()
        guard let image else { return }
        var shown = marks
        if let draft { shown.append(draft) }
        drawShot(image: image, imageSize: imageSize, marks: shown, in: fittedRect(), selected: selectedID)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let point = imagePoint(viewPoint) else { return }
        switch tool {
        case .select:
            dragPushed = false
            if let mark = marks.reversed().first(where: { shotMarkHit($0, point: point, slop: slop) }) {
                selectedID = mark.id
                dragOrigin = point
                dragOriginal = mark
                onStyle?(mark.ink, mark.textSize)
            } else {
                selectedID = nil
                dragOrigin = nil
                dragOriginal = nil
            }
        case .text:
            beginText(at: viewPoint)
        default:
            draft = ShotMark(id: UUID().uuidString, kind: kindName(tool), points: [ShotPoint(point)], text: "", textSize: textSize, ink: ink)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = imagePoint(convert(event.locationInWindow, from: nil)) else { return }
        switch tool {
        case .select:
            guard let origin = dragOrigin, let original = dragOriginal else { return }
            if !dragPushed {
                pushUndo()
                dragPushed = true
            }
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            var moved = original
            moved.points = original.points.map { ShotPoint(CGPoint(x: $0.point.x + dx, y: $0.point.y + dy)) }
            if let index = marks.firstIndex(where: { $0.id == original.id }) {
                marks[index] = moved
            }
        case .pencil:
            draft?.points.append(ShotPoint(point))
        case .line, .arrow, .rect:
            guard draft != nil else { return }
            if draft?.points.count == 1 {
                draft?.points.append(ShotPoint(point))
            } else if draft?.points.count ?? 0 >= 2 {
                draft?.points[1] = ShotPoint(point)
            }
        case .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard tool != .select, tool != .text else {
            dragOrigin = nil
            dragOriginal = nil
            return
        }
        guard let ready = draft else { return }
        draft = nil
        if ready.kind == "pencil" {
            guard ready.points.count >= 2 else { needsDisplay = true; return }
        } else if ready.points.count >= 2 {
            let start = ready.points[0].point
            let end = ready.points[1].point
            if hypot(start.x - end.x, start.y - end.y) < 3 {
                needsDisplay = true
                return
            }
        } else {
            needsDisplay = true
            return
        }
        pushUndo()
        marks.append(ready)
        selectedID = ready.id
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            deleteSelection()
        case 53:
            selectedID = nil
            needsDisplay = true
        default:
            super.keyDown(with: event)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === textField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = field.frame.origin
        textField = nil
        field.removeFromSuperview()
        guard !text.isEmpty, let point = imagePoint(origin) else { return }
        pushUndo()
        let mark = ShotMark(
            id: UUID().uuidString,
            kind: "text",
            points: [ShotPoint(point)],
            text: text,
            textSize: textSize,
            ink: ink
        )
        marks.append(mark)
        selectedID = mark.id
        needsDisplay = true
    }

    private func beginText(at viewPoint: CGPoint) {
        textField?.removeFromSuperview()
        let pointSize = max(13, CGFloat(textSize) * fitScale)
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 220, height: pointSize + 10))
        field.font = UtkaChrome.font(pointSize)
        field.textColor = ink.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.delegate = self
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
    }

    private func pushUndo() {
        history.append(marks)
        if history.count > 40 { history.removeFirst() }
    }

    /// Доли ширины картинки. Палитра переключает ступень, не произвольное число.
    static let fontScales: [Double] = [0.018, 0.028, 0.042, 0.06]

    private var textSize: Double {
        let step = min(max(0, fontStep), Self.fontScales.count - 1)
        return max(18, imageSize.width * Self.fontScales[step])
    }

    /// Новый цвет. Если пометка выбрана, красит и её.
    func useInk(_ next: ShotInk) {
        ink = next
        guard let selectedID, let index = marks.firstIndex(where: { $0.id == selectedID }) else { return }
        guard marks[index].ink != next else { return }
        pushUndo()
        marks[index].ink = next
        needsDisplay = true
    }

    /// Новая величина текста. Выбранная надпись меняется сразу.
    func useFontStep(_ step: Int) {
        fontStep = min(max(0, step), Self.fontScales.count - 1)
        guard let selectedID, let index = marks.firstIndex(where: { $0.id == selectedID }), marks[index].kind == "text" else { return }
        let size = textSize
        guard marks[index].textSize != size else { return }
        pushUndo()
        marks[index].textSize = size
        needsDisplay = true
    }
    private var slop: CGFloat { max(10, min(imageSize.width, imageSize.height) * 0.012) }
    private var fitScale: CGFloat { fittedRect().width / max(imageSize.width, 1) }

    private func fittedRect() -> CGRect {
        let inset = bounds.insetBy(dx: 16, dy: 16)
        guard imageSize.width > 0, imageSize.height > 0, inset.width > 0, inset.height > 0 else { return inset }
        let screen = window?.backingScaleFactor ?? 2
        let fit = min(inset.width / imageSize.width, inset.height / imageSize.height)
        let scale = min(fit, 1 / screen)
        let size = CGSize(width: (imageSize.width * scale).rounded(), height: (imageSize.height * scale).rounded())
        return CGRect(
            x: inset.minX + (inset.width - size.width) / 2,
            y: inset.minY + (inset.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func imagePoint(_ viewPoint: CGPoint) -> CGPoint? {
        let frame = fittedRect()
        guard frame.width > 0, frame.height > 0 else { return nil }
        let raw = CGPoint(
            x: (viewPoint.x - frame.minX) / frame.width * imageSize.width,
            y: (viewPoint.y - frame.minY) / frame.height * imageSize.height
        )
        guard raw.x >= -20, raw.y >= -20, raw.x <= imageSize.width + 20, raw.y <= imageSize.height + 20 else { return nil }
        return CGPoint(
            x: min(max(0, raw.x), imageSize.width),
            y: min(max(0, raw.y), imageSize.height)
        )
    }

    private func kindName(_ tool: ShotTool) -> String {
        switch tool {
        case .select: return "select"
        case .line: return "line"
        case .arrow: return "arrow"
        case .rect: return "rect"
        case .pencil: return "pencil"
        case .text: return "text"
        }
    }
}

/// Корень окна: раскладывает полосу и картинку сам, без уведомления о кадре.
final class ShotChromeRoot: NSView {
    var arrange: (() -> Void)?
    private var arranging = false

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard !arranging else { return }
        arranging = true
        arrange?()
        arranging = false
    }
}

/// Отдельное окно. Скрытие островка его не закрывает. Touch Bar агенту не нужен: на этом Маке он роняет процесс при перерисовке.
final class ShotWindow: NSWindow {
    var onUndo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func makeTouchBar() -> NSTouchBar? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 6 {
            onUndo?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Тонкая черта между группами полосы.
final class ShotBarDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSRect(x: bounds.midX - 0.5, y: (bounds.height - 14) / 2, width: 1, height: 14).fill()
    }
}

/// Подпись в полосе: по центру прямоугольника, гротеск продукта.
private func drawBarSign(_ text: String, in rect: NSRect, size: CGFloat = 14) {
    let font = UtkaChrome.font(size, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UtkaChrome.ink]
    let box = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
        at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2),
        withAttributes: attrs
    )
}

/// Цвета пометки.
final class ShotStyleBar: NSView {
    private var inkIndex = 0
    var onInk: ((Int) -> Void)?

    private static let swatch: CGFloat = 20

    var preferredWidth: CGFloat { CGFloat(ShotInk.palette.count) * Self.swatch }

    func reflect(inkIndex: Int) {
        self.inkIndex = inkIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, ink) in ShotInk.palette.enumerated() {
            let cell = NSRect(x: CGFloat(index) * Self.swatch, y: 0, width: Self.swatch, height: bounds.height)
            let dot = NSRect(x: cell.midX - 6, y: cell.midY - 6, width: 12, height: 12)
            ink.color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            let pale = ink.red > 0.92 && ink.green > 0.92 && ink.blue > 0.92
            if index == inkIndex || pale {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: -2.5, dy: -2.5))
                ring.lineWidth = 1
                let tone = index == inkIndex ? NSColor.white : NSColor.white.withAlphaComponent(0.28)
                (pale && index == inkIndex ? NSColor.white.withAlphaComponent(0.45) : tone).setStroke()
                ring.stroke()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        inkIndex = min(ShotInk.palette.count - 1, max(0, Int(point.x / Self.swatch)))
        needsDisplay = true
        onInk?(inkIndex)
    }
}

/// Ступень размера рядом с кнопкой текста.
final class ShotFontBar: NSView {
    private var fontStep = 1
    var onFont: ((Int) -> Void)?

    private static let labels = ["18", "28", "42", "60"]
    private static let stepHit: CGFloat = 22
    private static let labelWidth: CGFloat = 28

    var preferredWidth: CGFloat { Self.stepHit + Self.labelWidth + Self.stepHit }

    func reflect(fontStep: Int) {
        self.fontStep = fontStep
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let minus = NSRect(x: 0, y: 0, width: Self.stepHit, height: bounds.height)
        let labelBox = NSRect(x: minus.maxX, y: 0, width: Self.labelWidth, height: bounds.height)
        let plus = NSRect(x: labelBox.maxX, y: 0, width: Self.stepHit, height: bounds.height)
        drawBarSign("−", in: minus)
        drawBarSign(Self.labels[min(fontStep, Self.labels.count - 1)], in: labelBox, size: 11)
        drawBarSign("+", in: plus)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if point.x < Self.stepHit {
            shift(-1)
        } else if point.x >= Self.stepHit + Self.labelWidth {
            shift(1)
        }
    }

    private func shift(_ delta: Int) {
        let next = min(ShotCanvasView.fontScales.count - 1, max(0, fontStep + delta))
        guard next != fontStep else { return }
        fontStep = next
        needsDisplay = true
        onFont?(next)
    }
}

/// «Сохранить» сжимается в дискету. Кадры сами: аниматор окна у агента не тикает.
final class SaveDiskButton: NSView {
    var onPress: (() -> Void)?
    private(set) var folding = false
    private var fold: CGFloat = 0
    private var timer: Timer?
    private let label = "Сохранить"
    private let font = UtkaChrome.font(12, weight: .medium)

    var preferredWidth: CGFloat {
        let open = (label as NSString).size(withAttributes: [.font: font]).width + 12
        return open + (28 - open) * fold
    }

    deinit { timer?.invalidate() }

    /// Сжать подпись в значок. По окончании — закрыть редактор.
    func foldClosed(_ done: @escaping () -> Void) {
        guard !folding else { return }
        folding = true
        let start = Date()
        let duration = 0.46
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let t = min(1, Date().timeIntervalSince(start) / duration)
            let eased = t * t * (3 - 2 * t)
            self.fold = CGFloat(eased)
            self.needsDisplay = true
            self.onFrame?()
            guard t >= 1 else { return }
            timer.invalidate()
            self.timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: done)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    var onFrame: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let textAlpha = 1 - fold
        if textAlpha > 0.02 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(textAlpha)
            ]
            let size = (label as NSString).size(withAttributes: attrs)
            NSGraphicsContext.saveGraphicsState()
            let squeeze = NSAffineTransform()
            squeeze.translateX(by: bounds.midX, yBy: bounds.midY)
            squeeze.scaleX(by: 1 - 0.7 * fold, yBy: 1)
            squeeze.concat()
            (label as NSString).draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        if fold > 0.02 {
            drawDisk(alpha: min(1, (fold - 0.15) / 0.55))
        }
    }

    /// Контур дискеты в размер кнопки.
    private func drawDisk(alpha: CGFloat) {
        guard alpha > 0 else { return }
        let side: CGFloat = 15 * (0.55 + 0.45 * fold)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let color = NSColor.white.withAlphaComponent(alpha)
        color.setStroke()
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), xRadius: 1.4, yRadius: 1.4)
        body.lineWidth = 1.15
        body.stroke()
        let shutter = NSRect(
            x: rect.minX + side * 0.18,
            y: rect.maxY - side * 0.36,
            width: side * 0.64,
            height: side * 0.2
        )
        let metal = NSBezierPath(rect: shutter)
        metal.lineWidth = 1.05
        metal.stroke()
        let hub = NSRect(x: rect.midX - side * 0.13, y: rect.minY + side * 0.2, width: side * 0.26, height: side * 0.26)
        let hole = NSBezierPath(ovalIn: hub)
        hole.lineWidth = 1.05
        hole.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !folding else { return }
        onPress?()
    }
}

/// Редактор одного файла. Чужой файл не перезаписывает.
final class ShotEditorController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private var fileURL: URL
    private let source: CGImage
    private let window: ShotWindow
    private let canvas = ShotCanvasView()
    private let bar = NSView()
    private let status = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private var toolButtons: [NSButton] = []
    private var undoButton: NSButton!
    private let styleBar = ShotStyleBar()
    private let fontBar = ShotFontBar()
    private let toolDivider = ShotBarDivider()
    private let actionDivider = ShotBarDivider()
    private let saveButton = SaveDiskButton()
    private var saving = false

    init(url: URL, image: CGImage, marks: [ShotMark]) {
        fileURL = url
        source = image
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 960, height: 640)
        let size = NSSize(width: min(960, visible.width - 40), height: min(640, visible.height - 40))
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        window = ShotWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Снимок"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 640, height: 360)
        window.onUndo = { [weak self] in self?.canvas.undo() }
        buildChrome(marks: marks)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        let done = onClose
        onClose = nil
        DispatchQueue.main.async { done?() }
    }

    private func buildChrome(marks: [ShotMark]) {
        let root = ShotChromeRoot()
        root.arrange = { [weak self] in self?.layoutChrome() }
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1).cgColor
        window.contentView = root

        let picture = NSImage(cgImage: source, size: NSSize(width: source.width, height: source.height))
        canvas.image = picture
        canvas.imageSize = picture.size
        canvas.setMarks(marks)
        canvas.onStyle = { [weak self] ink, size in
            guard let self else { return }
            let ratio = size / Double(max(self.canvas.imageSize.width, 1))
            let step = ShotCanvasView.fontScales.enumerated().min {
                abs($0.element - ratio) < abs($1.element - ratio)
            }?.offset ?? self.canvas.fontStep
            self.canvas.ink = ink
            self.canvas.fontStep = step
            self.styleBar.reflect(inkIndex: ShotInk.nearest(ink))
            self.fontBar.reflect(fontStep: step)
        }

        bar.wantsLayer = true
        let tools: [(ShotTool, String, String)] = [
            (.select, "arrow.up.and.down.and.arrow.left.and.right", "Выбор"),
            (.line, "line.diagonal", "Линия"),
            (.arrow, "arrow.up.right", "Стрелка"),
            (.rect, "rectangle", "Периметр"),
            (.pencil, "pencil.tip", "Карандаш"),
            (.text, "textformat", "Текст")
        ]
        toolButtons = tools.map { tool, symbol, tip in
            let button = toolButton(symbol: symbol, tip: tip)
            button.tag = tool.rawValue
            button.action = #selector(toolTapped(_:))
            bar.addSubview(button)
            return button
        }
        undoButton = toolButton(symbol: "arrow.uturn.backward", tip: "Отменить")
        undoButton.action = #selector(undoTapped)

        styleBar.onInk = { [weak self] index in
            guard ShotInk.palette.indices.contains(index) else { return }
            self?.canvas.useInk(ShotInk.palette[index])
        }
        fontBar.onFont = { [weak self] step in self?.canvas.useFontStep(step) }
        bar.addSubview(fontBar)
        bar.addSubview(toolDivider)
        bar.addSubview(styleBar)
        bar.addSubview(actionDivider)
        bar.addSubview(undoButton)

        saveButton.onPress = { [weak self] in self?.saveTapped() }
        saveButton.onFrame = { [weak self] in self?.layoutChrome() }
        bar.addSubview(saveButton)
        bar.addSubview(status)
        root.addSubview(bar)
        root.addSubview(canvas)
        showTool(.select)
        layoutChrome()
    }

    /// Кнопка полосы: знак, без подписи.
    private func toolButton(symbol: String, tip: String) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        button.contentTintColor = UtkaChrome.ink
        button.toolTip = tip
        button.target = self
        return button
    }

    private func layoutChrome() {
        guard let root = window.contentView else { return }
        let barH: CGFloat = 40
        bar.frame = NSRect(x: 0, y: 0, width: root.bounds.width, height: barH)
        canvas.frame = NSRect(x: 0, y: barH, width: root.bounds.width, height: max(0, root.bounds.height - barH))
        let inset: CGFloat = 12
        let slot = NSSize(width: 28, height: 28)
        var x = inset
        for button in toolButtons {
            button.frame = NSRect(origin: NSPoint(x: x, y: 6), size: slot)
            x += 32
            if button.tag == ShotTool.text.rawValue {
                fontBar.frame = NSRect(x: x - 4, y: 6, width: fontBar.preferredWidth, height: 28)
                x = fontBar.frame.maxX + 4
            }
        }
        toolDivider.frame = NSRect(x: x + 6, y: 6, width: 1, height: 28)
        let styleW = styleBar.preferredWidth
        styleBar.frame = NSRect(x: toolDivider.frame.maxX + 12, y: 6, width: styleW, height: 28)
        let saveW = saveButton.preferredWidth
        saveButton.frame = NSRect(x: bar.bounds.width - saveW - inset, y: 6, width: saveW, height: 28)
        undoButton.frame = NSRect(x: saveButton.frame.minX - 8 - slot.width, y: 6, width: slot.width, height: slot.height)
        actionDivider.frame = NSRect(x: undoButton.frame.minX - 14, y: 6, width: 1, height: 28)
        let statusX = styleBar.frame.maxX + 12
        let statusW = actionDivider.frame.minX - 12 - statusX
        status.frame = NSRect(x: statusX, y: 11, width: max(0, statusW), height: 16)
        status.isHidden = status.stringValue.isEmpty || statusW < 24
    }

    @objc private func toolTapped(_ sender: NSButton) {
        guard let tool = ShotTool(rawValue: sender.tag) else { return }
        canvas.tool = tool
        showTool(tool)
        window.makeFirstResponder(canvas)
    }

    @objc private func undoTapped() {
        canvas.undo()
    }

    /// Короткий статус в свободном месте полосы. Пустая строка прячет подпись.
    private func noteStatus(_ text: String) {
        status.stringValue = text
        layoutChrome()
    }

    private func saveTapped() {
        guard !saving else { return }
        let ownedPNG = UtkaPaths.ownsShot(fileURL.path) && fileURL.pathExtension.lowercased() == "png"
        let dest = ownedPNG ? fileURL : freshURL()
        if !FileManager.default.fileExists(atPath: ShotStore.baseURL(for: dest).path) {
            guard ShotStore.writeImage(source, to: ShotStore.baseURL(for: dest)) else {
                noteStatus("Не записать")
                return
            }
        }
        guard let data = flattenShot(image: source, marks: canvas.marks) else {
            noteStatus("Не записать")
            return
        }
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            noteStatus("Не записать")
            return
        }
        ShotStore.writeMarks(canvas.marks, beside: dest)
        noteStatus("")
        if ownedPNG {
            ShotEditor.shelf?.noteFileChanged()
        } else {
            let previous = fileURL.standardizedFileURL.path
            fileURL = dest
            ShotEditor.retarget(from: previous, to: dest.path, controller: self)
            ShotEditor.shelf?.add(urls: [dest])
        }
        saving = true
        saveButton.foldClosed { [weak self] in
            self?.window.close()
        }
    }

    private func freshURL() -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var dest = UtkaPaths.shots.appendingPathComponent("Пометка \(stamp.string(from: Date())).png")
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = UtkaPaths.shots.appendingPathComponent("Пометка \(UUID().uuidString.prefix(8)).png")
        }
        return dest
    }

    private func showTool(_ tool: ShotTool) {
        for button in toolButtons where button.action == #selector(toolTapped(_:)) {
            let on = button.tag == tool.rawValue
            button.contentTintColor = on ? UtkaChrome.ink : UtkaChrome.dim
        }
    }
}

/// Вход редактора. Полка, заготовка и будущий правый клик зовут одно и то же.
enum ShotEditor {
    static weak var shelf: ShelfModel?
    private static var windows: [String: ShotEditorController] = [:]

    static func open(url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = windows[path] {
            existing.show()
            return
        }
        guard FileManager.default.fileExists(atPath: path), let loaded = ShotStore.load(url: url) else { return }
        let controller = ShotEditorController(url: url, image: loaded.image, marks: loaded.marks)
        windows[path] = controller
        controller.onClose = { windows[path] = nil }
        controller.show()
    }

    static func retarget(from previous: String, to path: String, controller: ShotEditorController) {
        if windows[previous] === controller { windows[previous] = nil }
        windows[path] = controller
        controller.onClose = { windows[path] = nil }
    }
}
