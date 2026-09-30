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

    /// Имя в списке настроек. Подсказка на островке остаётся своей.
    var listTitle: String {
        switch self {
        case .shelf: return "Полка"
        case .clipboard: return "Буфер"
        case .presets: return "Закрепы"
        case .translate: return "Переводчик"
        }
    }

    /// Короткий id в каталоге и в памяти порядка.
    var slotID: String {
        switch self {
        case .shelf: return "shelf"
        case .clipboard: return "clipboard"
        case .presets: return "presets"
        case .translate: return "translate"
        }
    }

    init?(slotID: String) {
        switch slotID {
        case "shelf": self = .shelf
        case "clipboard": self = .clipboard
        case "presets": self = .presets
        case "translate": self = .translate
        default: return nil
        }
    }

    static let orderChanged = Notification.Name("utka.sectionOrder")
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

/// Обводка капли. Клики проходят к кнопкам под ней.
private final class DropStroke: NSView {
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
    var line: CAShapeLayer { layer as! CAShapeLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Чёрная капля: верхние углы выпуклые, плашка шире книзу и держится за кромку.
final class IslandRoot: NSView {
    /// Радиус ушей. Бок кончается на той же дуге, иначе контур рвётся.
    private let earRadius: CGFloat = 18
    /// Радиус нижнего скругления.
    private let bottomRadius: CGFloat = 36
    /// Высота капли от кромки. nil — весь островок.
    private var revealHeight: CGFloat?
    /// Чёрная дуга. Вектор, не картинка. Заливка живёт на вуали, дуга только держит форму.
    private let shape = CAShapeLayer()
    /// Та же дуга обрезает содержимое.
    private let clip = CAShapeLayer()
    /// Матовое стекло под вуалью. При нулевой прозрачности спрятано.
    private let frost = NSVisualEffectView()
    /// Плотная заливка. Прозрачность стекла её разбавляет.
    private let veil = NSView()
    private let frostMask = CAShapeLayer()
    private let veilMask = CAShapeLayer()
    /// Обводка поверх вуали. Сама заливка её не закрывает.
    private let strokeHost = DropStroke()
    private var plantedGlass = false
    private var wasDark = IslandLook.dark
    /// Нижняя дуга выше кромки окна, прямоугольник её не срезает.
    private let bottomInset: CGFloat = 2

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        applyShape()
    }

    /// Высота видимой капли от верхней кромки. nil — островок целиком.
    fileprivate func setReveal(_ height: CGFloat?) {
        revealHeight = height
        applyShape()
    }

    /// Чёрная капля в видимой полосе. Фон пустой, без растровой маски.
    private func applyShape() {
        wantsLayer = true
        layer?.backgroundColor = nil
        let full = bounds
        let screen = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let visible = revealHeight.map { min(max($0, 0), full.height) } ?? full.height
        guard full.width > 1, full.height > 1, visible > bottomInset + 1 else {
            shape.path = nil
            clip.path = nil
            return
        }
        let drawn = visible - bottomInset
        // Полоса на видимую высоту. Короче капли — уши сами едут к центру, кромка экран не режет.
        let band = CGRect(x: 0, y: full.height - visible, width: full.width, height: visible)
        let shapeBounds = CGRect(x: 0, y: bottomInset, width: band.width, height: drawn)
        let clipBounds = CGRect(x: 0, y: full.height - visible + bottomInset, width: full.width, height: drawn)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plantGlass()
        frost.frame = full
        veil.frame = full
        frost.appearance = IslandLook.appearance
        frost.isHidden = IslandLook.glass < 0.02
        veil.layer?.backgroundColor = IslandLook.veil.cgColor
        frostMask.frame = full
        veilMask.frame = full
        shape.contentsScale = screen
        shape.fillColor = NSColor.clear.cgColor
        shape.allowsEdgeAntialiasing = true
        shape.masksToBounds = false
        shape.frame = band
        shape.path = islandSilhouette(bounds: shapeBounds, ear: earRadius, bottom: bottomRadius)
        if shape.superlayer == nil {
            layer?.insertSublayer(shape, at: 0)
        }
        clip.contentsScale = screen
        clip.fillColor = NSColor.black.cgColor
        clip.allowsEdgeAntialiasing = true
        clip.frame = CGRect(origin: .zero, size: full.size)
        clip.path = islandSilhouette(bounds: clipBounds, ear: earRadius, bottom: bottomRadius)
        frostMask.path = clip.path
        veilMask.path = clip.path
        if let path = clip.path { placeStroke(path: path, screen: screen) }
        layer?.mask = clip
        CATransaction.commit()
    }

    /// Линия по силуэту поверх заливки. Маска капли оставляет внутреннюю половину.
    private func placeStroke(path: CGPath, screen: CGFloat) {
        if strokeHost.superview == nil {
            addSubview(strokeHost, positioned: .above, relativeTo: nil)
        }
        strokeHost.frame = bounds
        let line = strokeHost.line
        line.frame = bounds
        line.path = path
        line.fillColor = nil
        line.lineJoin = .round
        line.lineWidth = IslandLook.strokeOn ? 5 : 0
        line.strokeColor = IslandLook.strokeOn ? IslandLook.strokeColor.cgColor : nil
        line.contentsScale = screen
    }

    /// Стекло и вуаль под содержимым, в той же маске капли.
    private func plantGlass() {
        guard !plantedGlass else { return }
        plantedGlass = true
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.wantsLayer = true
        veil.wantsLayer = true
        frost.layer?.mask = frostMask
        veil.layer?.mask = veilMask
        addSubview(frost, positioned: .below, relativeTo: nil)
        addSubview(veil, positioned: .above, relativeTo: frost)
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: IslandLook.changed, object: nil)
    }

    @objc private func lookChanged() {
        frost.material = IslandLook.dark ? .hudWindow : .menu
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard IslandLook.mode == .system else { return }
        let now = IslandLook.dark
        guard now != wasDark else { return }
        wasDark = now
        IslandLook.poke()
    }

    /// Уши на всю кромку, пока капля высокая. У кромки экрана уши съезжают к центру.
    private func islandSilhouette(bounds: CGRect, ear: CGFloat, bottom: CGFloat) -> CGPath {
        let span = ear + bottom
        if bounds.height < span {
            return suckedSilhouette(bounds: bounds, ear: ear, bottom: bottom)
        }
        return restingSilhouette(bounds: bounds, ear: ear, bottom: bottom)
    }

    /// Полная капля: уши по краям, низ 36.
    private func restingSilhouette(bounds: CGRect, ear: CGFloat, bottom: CGFloat) -> CGPath {
        let x0 = bounds.minX
        let y0 = bounds.minY
        let width = bounds.width
        let top = y0 + bounds.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: top))
        path.addLine(to: CGPoint(x: x0 + width, y: top))
        addCorner(
            path,
            center: CGPoint(x: x0 + width, y: top - ear),
            radius: ear,
            start: .pi / 2,
            end: .pi,
            clockwise: false
        )
        path.addLine(to: CGPoint(x: x0 + width - ear, y: y0 + bottom))
        addCorner(
            path,
            center: CGPoint(x: x0 + width - ear - bottom, y: y0 + bottom),
            radius: bottom,
            start: 0,
            end: -.pi / 2,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: x0 + ear + bottom, y: y0))
        addCorner(
            path,
            center: CGPoint(x: x0 + ear + bottom, y: y0 + bottom),
            radius: bottom,
            start: -.pi / 2,
            end: .pi,
            clockwise: true
        )
        path.addLine(to: CGPoint(x: x0 + ear, y: top - ear))
        addCorner(
            path,
            center: CGPoint(x: x0, y: top - ear),
            radius: ear,
            start: 0,
            end: .pi / 2,
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    /// Короткая капля: ухо и низ касаются, уши едут к центру, верх встречается с экраном по горизонтали.
    private func suckedSilhouette(bounds: CGRect, ear: CGFloat, bottom: CGFloat) -> CGPath {
        let x0 = bounds.minX
        let y0 = bounds.minY
        let width = bounds.width
        let height = bounds.height
        let span = ear + bottom
        // Радиусы как у полной капли: ухо 18, низ 36. Окно дугу не режет.
        let pull = neckPull(height: height, span: span, width: width)
        let apart = sqrt(max(0, height * (2 * span - height)))
        let rightBottom = CGPoint(x: x0 + width - span - pull, y: y0 + bottom)
        let rightEar = CGPoint(x: rightBottom.x + apart, y: y0 + height - ear)
        let leftBottom = CGPoint(x: x0 + span + pull, y: y0 + bottom)
        let leftEar = CGPoint(x: leftBottom.x - apart, y: rightEar.y)
        let rightTouch = step(from: rightEar, toward: rightBottom, distance: ear)
        let leftTouch = step(from: leftEar, toward: leftBottom, distance: ear)
        let top = y0 + height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: leftEar.x, y: top))
        path.addLine(to: CGPoint(x: rightEar.x, y: top))
        addShortArc(path, center: rightEar, radius: ear, from: .pi / 2, to: angle(from: rightEar, to: rightTouch))
        addShortArc(path, center: rightBottom, radius: bottom, from: angle(from: rightBottom, to: rightTouch), to: -.pi / 2)
        path.addLine(to: CGPoint(x: leftBottom.x, y: y0))
        addShortArc(path, center: leftBottom, radius: bottom, from: -.pi / 2, to: angle(from: leftBottom, to: leftTouch))
        addShortArc(path, center: leftEar, radius: ear, from: angle(from: leftEar, to: leftTouch), to: .pi / 2)
        path.closeSubpath()
        return path
    }

    /// Мёд к центру: 0 у полной капли, плавно до середины к концу.
    private func neckPull(height: CGFloat, span: CGFloat, width: CGFloat) -> CGFloat {
        let t = min(1, max(0, (span - height) / span))
        let eased = t * t * (3 - 2 * t)
        return eased * max(0, width * 0.5 - span)
    }

    /// Короткая дуга между углами. Длинный обход вылезает из капли и срезается острым углом.
    private func addShortArc(_ path: CGMutablePath, center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) {
        var delta = end - start
        let turn = CGFloat.pi * 2
        while delta > .pi { delta -= turn }
        while delta <= -.pi { delta += turn }
        addCorner(path, center: center, radius: radius, start: start, end: start + delta, clockwise: delta < 0)
    }

    /// Точка на отрезке в заданном расстоянии от начала.
    private func step(from start: CGPoint, toward end: CGPoint, distance: CGFloat) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return start }
        let scale = distance / length
        return CGPoint(x: start.x + dx * scale, y: start.y + dy * scale)
    }

    /// Угол от центра к точке.
    private func angle(from center: CGPoint, to point: CGPoint) -> CGFloat {
        atan2(point.y - center.y, point.x - center.x)
    }

    /// Дуга угла. Нулевой радиус не рисует дугу, контур идёт прямой.
    private func addCorner(_ path: CGMutablePath, center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool) {
        guard radius > 0.25 else { return }
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    }
}

/// Знак снимка сразу в размер кнопки. Иначе система сжимает файл в 24 пикселя и растягивает их на сетчатке.
private func shotMark(url: URL) -> NSImage? {
    guard let source = NSImage(contentsOf: url) else { return nil }
    let side: CGFloat = 24
    let image = NSImage(size: NSSize(width: side, height: side))
    let full = NSRect(origin: .zero, size: source.size)
    for scale in [2, 3] {
        let pixels = Int((side * CGFloat(scale)).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { continue }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: full, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(rep)
    }
    image.isTemplate = false
    return image.representations.isEmpty ? nil : image
}

/// Цель кнопки снимка: сама панель не наследник NSObject.
private final class ShotButtonTarget: NSObject {
    var fire: () -> Void = {}
    @objc func take() {
        fire()
    }
}

/// Ползунок, который сообщает, когда его тянут, чтобы не перетирать позицию из CoreAudio.
private final class VolumeSlider: NSSlider {
    var onTracking: ((Bool) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onTracking?(true)
        super.mouseDown(with: event)
        onTracking?(false)
    }
}

/// Громкость, круглая кнопка источников и поле поиска. Слева от снимка.
final class SoundStrip: NSView {
    private let muteButton = NSButton()
    private let slider = VolumeSlider()
    private let sourcesButton = NSButton()
    private let searchField = NSSearchField()
    private var trackingVolume = false
    private var soundOn = IslandBar.sound
    private var searchOn = IslandBar.search
    private var sourcesOpen = false
    var onLookup: ((String) -> Void)?
    var onMove: ((Int) -> Void)?
    var onCommit: (() -> Void)?
    /// Круглая кнопка открывает или закрывает список выходов.
    var onToggleSources: (() -> Void)?
    /// Список выходов или громкость изменились.
    var onAudio: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.imageScaling = .scaleProportionallyDown
        muteButton.toolTip = "Беззвучие"
        muteButton.target = self
        muteButton.action = #selector(muteClicked)
        muteButton.focusRingType = .none
        addSubview(muteButton)

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.focusRingType = .none
        slider.target = self
        slider.action = #selector(volumeMoved(_:))
        slider.toolTip = "Громкость"
        slider.onTracking = { [weak self] tracking in
            self?.trackingVolume = tracking
            if !tracking { self?.apply() }
        }
        addSubview(slider)

        sourcesButton.isBordered = false
        sourcesButton.imagePosition = .imageOnly
        sourcesButton.imageScaling = .scaleProportionallyDown
        sourcesButton.toolTip = "Источники звука"
        sourcesButton.target = self
        sourcesButton.action = #selector(sourcesClicked)
        sourcesButton.focusRingType = .none
        sourcesButton.wantsLayer = true
        sourcesButton.layer?.cornerRadius = 12
        sourcesButton.layer?.masksToBounds = true
        addSubview(sourcesButton)

        searchField.font = UtkaChrome.font(12)
        searchField.textColor = UtkaChrome.ink
        searchField.placeholderString = "Поиск Spotlight"
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = true
        searchField.delegate = self
        addSubview(searchField)

        AudioOutput.shared.onChange = { [weak self] in self?.apply() }
        AudioOutput.shared.start()
    }

    required init?(coder: NSCoder) { nil }

    override var frame: NSRect {
        didSet {
            if frame.size != oldValue.size { place() }
        }
    }

    /// Звук и поиск ставятся рядом. Выключенный звук прячет круглую кнопку.
    func setBar(sound: Bool, search: Bool) {
        let wasSearch = searchOn
        soundOn = sound
        searchOn = search
        if !search, wasSearch {
            searchField.stringValue = ""
            onLookup?("")
        }
        if !sound { sourcesOpen = false }
        place()
        paintSourcesButton()
    }

    /// Кружок подсвечен, пока список источников открыт.
    func setSourcesOpen(_ open: Bool) {
        sourcesOpen = open
        paintSourcesButton()
    }

    /// Прямоугольник поля в координатах островка.
    func fieldFrame(in view: NSView) -> NSRect? {
        guard searchOn, !searchField.isHidden, searchField.bounds.width > 1 else { return nil }
        return searchField.convert(searchField.bounds, to: view)
    }

    /// Прямоугольник круглой кнопки в координатах островка.
    func sourcesFrame(in view: NSView) -> NSRect? {
        guard soundOn, !sourcesButton.isHidden, sourcesButton.bounds.width > 1 else { return nil }
        return sourcesButton.convert(sourcesButton.bounds, to: view)
    }

    /// Слева значок выхода, затем колонка беззвучия, ползунок и поиск.
    private func place() {
        let bar = bounds.height
        muteButton.isHidden = false
        slider.isHidden = false
        var origin: CGFloat = 0
        sourcesButton.isHidden = !soundOn
        if soundOn {
            sourcesButton.frame = NSRect(x: origin, y: (bar - 24) / 2, width: 24, height: 24)
            origin += 32
        }
        muteButton.frame = NSRect(x: origin, y: (bar - 24) / 2, width: 24, height: 24)
        origin += 28
        let sliderWidth = min(120, max(72, bounds.width * 0.22))
        slider.frame = NSRect(x: origin, y: (bar - 18) / 2, width: sliderWidth, height: 18)
        origin = slider.frame.maxX + 8
        searchField.isHidden = !searchOn
        guard searchOn else { return }
        searchField.frame = NSRect(x: origin, y: (bar - 22) / 2, width: max(40, bounds.width - origin), height: 22)
    }

    /// Подтягивает громкость, колонку беззвучия и значок текущего выхода.
    private func apply() {
        let audio = AudioOutput.shared
        slider.isEnabled = audio.canAdjustVolume
        slider.alphaValue = audio.canAdjustVolume ? 1 : 0.35
        slider.toolTip = audio.canAdjustVolume ? "Громкость" : "Нет регулировки"
        if !trackingVolume, audio.canAdjustVolume, abs(slider.doubleValue - Double(audio.volume)) > 0.001 {
            slider.doubleValue = Double(audio.volume)
        }
        muteButton.isEnabled = audio.canMute
        muteButton.toolTip = "Беззвучие"
        let symbol = speakerSymbol(volume: audio.volume, muted: audio.muted, adjustable: audio.canAdjustVolume || audio.canMute)
        muteButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Громкость")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        muteButton.contentTintColor = muteButton.isEnabled ? UtkaChrome.ink : UtkaChrome.dim
        paintSourcesButton()
        onAudio?()
    }

    /// Кружок слева от ползунка. Значок — Мак, монитор или наушники.
    private func paintSourcesButton() {
        let audio = AudioOutput.shared
        let sink = audio.sinks.first { $0.id == audio.currentID }
        let symbol = sink?.symbol ?? "laptopcomputer"
        sourcesButton.toolTip = sink?.name ?? "Источники звука"
        sourcesButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: sink?.name ?? "Источники звука")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let color = sourcesOpen ? IslandLook.accent : UtkaChrome.ink
        sourcesButton.contentTintColor = color
        sourcesButton.layer?.backgroundColor = (sourcesOpen ? IslandLook.accent.withAlphaComponent(0.22) : UtkaChrome.card).cgColor
    }

    /// Значок динамика по громкости и беззвучию.
    private func speakerSymbol(volume: Float, muted: Bool, adjustable: Bool) -> String {
        if !adjustable { return "speaker.wave.2" }
        if muted || volume <= 0.001 { return "speaker.slash" }
        if volume < 0.33 { return "speaker" }
        if volume < 0.66 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }

    @objc private func sourcesClicked() {
        onToggleSources?()
    }

    /// Чернила поля и кнопок под текущий вид.
    func applyChrome() {
        searchField.textColor = UtkaChrome.ink
        apply()
    }

    @objc private func muteClicked() {
        AudioOutput.shared.toggleMute()
    }

    @objc private func volumeMoved(_ sender: NSSlider) {
        AudioOutput.shared.setVolume(Float(sender.doubleValue))
    }
}

/// Поле поиска: набор текста, стрелки и Enter. Command+пробел не перехватывает.
extension SoundStrip: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onLookup?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            onMove?(1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            onMove?(-1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        return false
    }
}

/// Список выходов под круглой кнопкой.
final class SourceDrop: NSView {
    var onPick: ((AudioOutput.Sink) -> Void)?
    private var sinks: [AudioOutput.Sink] = []
    private var current: UInt32 = 0
    private var rows: [NSButton] = []

    /// Высота списка. Пустой список всё равно занимает одну строку.
    var neededHeight: CGFloat { CGFloat(max(sinks.count, 1)) * 32 + 8 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.backgroundColor = IslandLook.solid.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !isHidden else { return }
        paint()
    }

    /// Показывает выходы или прячет список.
    func show(open: Bool, sinks: [AudioOutput.Sink], current: UInt32) {
        guard open else {
            close()
            return
        }
        let same = !isHidden && sinks == self.sinks && current == self.current
        self.sinks = sinks
        self.current = current
        isHidden = false
        if same { return }
        rebuild()
    }

    func close() {
        guard !isHidden || !rows.isEmpty else { return }
        isHidden = true
        sinks = []
        rows.forEach { $0.removeFromSuperview() }
        rows = []
    }

    /// Плотная плашка, чтобы имена читались и на стекле.
    func retint() {
        layer?.backgroundColor = IslandLook.solid.cgColor
        paint()
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        if sinks.isEmpty {
            rows = [makeRow(title: "Нет источников", symbol: "speaker.slash", index: -1)]
        } else {
            rows = sinks.enumerated().map { index, sink in
                makeRow(title: sink.name, symbol: sink.symbol, index: index)
            }
        }
        paint()
    }

    /// Строка выхода: значок транспорта и имя.
    private func makeRow(title: String, symbol: String, index: Int) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.imageHugsTitle = true
        button.alignment = .left
        button.lineBreakMode = .byTruncatingTail
        button.font = UtkaChrome.font(12, weight: .medium)
        button.title = title
        button.tag = index
        button.target = self
        button.action = #selector(clicked(_:))
        button.focusRingType = .none
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        addSubview(button)
        return button
    }

    private func paint() {
        let width = bounds.width
        for (index, button) in rows.enumerated() {
            let on = sinks.indices.contains(index) && sinks[index].id == current
            let color = on ? IslandLook.accent : UtkaChrome.dim
            button.frame = NSRect(x: 4, y: bounds.height - CGFloat(index + 1) * 32, width: max(40, width - 8), height: 30)
            button.contentTintColor = color
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [
                    .font: UtkaChrome.font(12, weight: on ? .semibold : .medium),
                    .foregroundColor: color
                ]
            )
            button.layer?.backgroundColor = (on ? IslandLook.accent.withAlphaComponent(0.22) : NSColor.clear).cgColor
        }
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sinks.indices.contains(sender.tag) else { return }
        onPick?(sinks[sender.tag])
    }
}

/// Островок у верхнего края выбранного экрана.
final class IslandPanel {
    let window: KeyPanel
    /// Обрезает корень по рамке окна. Сам корень не сжимается.
    private let host = NSView()
    private let root = IslandRoot()
    /// Верхняя полоса на все разделы. Сюда сядут кнопки, подпись раздела не нужна.
    private let topBar = NSView()
    private let soundStrip = SoundStrip()
    private let spot = IslandSearch()
    private let searchDrop = SearchDrop()
    private let sourceDrop = SourceDrop()
    private var sourcesOpen = false
    private let shotButton = NSButton()
    private let shotTarget = ShotButtonTarget()
    private let body = NSView()
    private let sectionRail = NSView()
    private var bodies: [String: NSView] = [:]
    private var railButtons: [SectionRailButton] = []
    private var buttonTargets: [String: NSRect] = [:]
    private var buttonMotion: Timer?
    private var currentID = IslandSection.shelf.slotID
    private weak var clickTarget: AnyObject?
    private var clickAction: Selector?
    private var slideTimer: Timer?
    private var slideFrom: CGRect = .zero
    private var slideTo: CGRect = .zero
    private var slideStart: Date?
    private var slideOrderOut = false
    /// Полный размер островка, пока окно растёт вниз от кромки.
    private var resting = CGRect.zero
    var onSection: ((IslandSection) -> Void)?
    var onCapture: (() -> Void)?
    var onSettings: (() -> Void)?

    /// Подтягивает каплю, разделы и полосу под сохранённый вид.
    func applyLook() {
        window.appearance = IslandLook.appearance
        root.needsLayout = true
        soundStrip.applyChrome()
        searchDrop.retint()
        sourceDrop.retint()
        show(id: currentID)
    }

    /// Меняет полосу, кнопку снимка не двигает.
    func setBar() {
        soundStrip.setBar(sound: IslandBar.sound, search: IslandBar.search)
        if !IslandBar.search { searchDrop.show([]) }
        if !IslandBar.sound { sourcesOpen = false }
        refreshSources()
    }

    /// Список Spotlight под полем, не задевая кнопку снимка.
    private func placeSearchDrop() {
        guard !searchDrop.isHidden, let anchor = soundStrip.fieldFrame(in: root) else {
            searchDrop.isHidden = true
            return
        }
        let area = body.frame
        let top = min(anchor.minY - 4, area.maxY)
        let fitted = min(searchDrop.neededHeight, max(32, top - area.minY))
        searchDrop.frame = NSRect(x: area.minX, y: top - fitted, width: area.width, height: fitted)
    }

    /// Список источников под круглой кнопкой, не шире тела островка.
    private func placeSourceDrop() {
        guard sourcesOpen, let anchor = soundStrip.sourcesFrame(in: root) else {
            sourceDrop.isHidden = true
            return
        }
        let area = body.frame
        let width = min(240, area.width)
        let top = min(anchor.minY - 4, area.maxY)
        let fitted = min(sourceDrop.neededHeight, max(32, top - area.minY))
        var x = anchor.minX
        if x + width > area.maxX { x = max(area.minX, area.maxX - width) }
        sourceDrop.isHidden = false
        sourceDrop.frame = NSRect(x: x, y: top - fitted, width: width, height: fitted)
    }

    /// Открывает или закрывает список выходов.
    private func toggleSources() {
        guard IslandBar.sound else { return }
        sourcesOpen.toggle()
        refreshSources()
    }

    /// Перерисовывает список, если он открыт, и кружок на полосе.
    private func refreshSources() {
        let open = sourcesOpen && IslandBar.sound
        sourcesOpen = open
        sourceDrop.show(open: open, sinks: AudioOutput.shared.sinks, current: AudioOutput.shared.currentID)
        soundStrip.setSourcesOpen(open)
        placeSourceDrop()
    }

    init(shelf: NSView, clipboard: NSView, presets: NSView, translator: NSView, mark: NSImage?) {
        bodies = [
            IslandSection.shelf.slotID: shelf,
            IslandSection.clipboard.slotID: clipboard,
            IslandSection.presets.slotID: presets,
            IslandSection.translate.slotID: translator
        ]
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
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.appearance = IslandLook.appearance
        window = panel

        root.wantsLayer = true
        root.autoresizingMask = []
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        host.addSubview(root)
        panel.contentView = host
        root.frame = host.bounds

        let markView = DuckMarkView()
        markView.image = mark.map { MenuMark.cutout(from: $0) }
        sectionRail.addSubview(markView)
        syncRail()

        shotButton.isBordered = false
        shotButton.imagePosition = .imageOnly
        shotButton.imageScaling = .scaleProportionallyDown
        if let url = Bundle.main.url(forResource: "shot-mark", withExtension: "png") {
            shotButton.image = shotMark(url: url)
        }
        shotButton.contentTintColor = nil
        shotButton.toolTip = "Снимок области"
        shotTarget.fire = { [weak self] in self?.onCapture?() }
        shotButton.target = shotTarget
        shotButton.action = #selector(ShotButtonTarget.take)
        topBar.addSubview(soundStrip)
        topBar.addSubview(shotButton)
        root.addSubview(sectionRail)
        root.addSubview(topBar)
        root.addSubview(body)
        root.addSubview(searchDrop)
        root.addSubview(sourceDrop)
        sourceDrop.onPick = { [weak self] sink in
            guard let self else { return }
            self.sourcesOpen = false
            AudioOutput.shared.select(sink.id)
            self.refreshSources()
        }
        soundStrip.onToggleSources = { [weak self] in self?.toggleSources() }
        soundStrip.onAudio = { [weak self] in self?.refreshSources() }
        spot.onHits = { [weak self] hits in
            self?.searchDrop.show(hits)
            self?.placeSearchDrop()
        }
        searchDrop.onPick = { hit in IslandSearch.open(hit) }
        soundStrip.onLookup = { [weak self] text in self?.spot.lookup(text) }
        soundStrip.onMove = { [weak self] delta in self?.searchDrop.move(delta) }
        soundStrip.onCommit = { [weak self] in
            guard let hit = self?.searchDrop.current() else { return }
            IslandSearch.open(hit)
        }
        show(id: IslandSection.shelf.slotID)

        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: root, queue: .main) { _ in
            self.sectionRail.frame = NSRect(x: 0, y: 0, width: 88, height: self.root.bounds.height)
            markView.frame = NSRect(x: 44, y: self.root.bounds.height - 86, width: 40, height: 40)
            self.placeSectionButtons(animated: false)
            let bottom: CGFloat = 14
            let right: CGFloat = 48
            let barH: CGFloat = 32
            self.topBar.frame = NSRect(x: 96, y: self.root.bounds.height - 12 - barH, width: max(120, self.root.bounds.width - 96 - right), height: barH)
            self.shotButton.frame = NSRect(x: self.topBar.bounds.width - 28, y: 4, width: 24, height: 24)
            self.soundStrip.frame = NSRect(x: 0, y: 0, width: max(0, self.shotButton.frame.minX - 8), height: barH)
            let bodyTop = self.root.bounds.height - 12 - barH - 8
            self.body.frame = NSRect(
                x: 96,
                y: bottom,
                width: max(120, self.root.bounds.width - 96 - right),
                height: max(80, bodyTop - bottom)
            )
            if let visible = self.body.subviews.first {
                visible.frame = self.body.bounds
                visible.resizeSubviews(withOldSize: visible.bounds.size)
            }
            self.placeSearchDrop()
            self.placeSourceDrop()
        }
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: root)
        markView.onClick = { [weak self] in self?.onSettings?() }
        NotificationCenter.default.addObserver(forName: IslandLook.changed, object: nil, queue: .main) { [weak self] _ in
            self?.applyLook()
        }
        NotificationCenter.default.addObserver(forName: IslandSection.orderChanged, object: nil, queue: .main) { [weak self] _ in
            self?.syncRail()
            self?.placeSectionButtons(animated: true)
        }
        applyLook()
    }

    /// Кнопки разделов сверху вниз в сохранённом порядке. Четыре ядровых остаются 36×36 с шагом 42.
    private func placeSectionButtons(animated: Bool) {
        let visible = SectionBoard.visible
        let metrics = railMetrics(count: max(visible.count, 1))
        var y = root.bounds.height - 132
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let visibleIDs = Set(visible.map(\.id))
        for button in railButtons {
            let on = visibleIDs.contains(button.slotID)
            button.isHidden = !on
            button.updateSymbol(point: metrics.symbol)
            if !on { buttonTargets.removeValue(forKey: button.slotID) }
        }
        for slot in visible {
            guard let button = railButtons.first(where: { $0.slotID == slot.id }) else { continue }
            let target = NSRect(x: 64 - metrics.size / 2, y: y, width: metrics.size, height: metrics.size)
            y -= metrics.pitch
            buttonTargets[slot.id] = target
            if !animated || button.frame == .zero {
                button.frame = target
            }
        }
        CATransaction.commit()
        if animated { kickButtonMotion() }
        if !visibleIDs.contains(currentID), let next = visible.first {
            select(slotID: next.id)
        }
    }

    /// Шаг полосы. При четырёх и меньше кадр прежний, дальше значки сжимаются внутри той же высоты.
    private func railMetrics(count: Int) -> (size: CGFloat, pitch: CGFloat, symbol: CGFloat) {
        if count <= 4 { return (36, 42, 16) }
        let room = max(36, root.bounds.height - 132 - 14)
        let fitted = room / CGFloat(max(count - 1, 1))
        let pitch = min(42, max(22, fitted))
        let size = min(36, pitch)
        return (size, pitch, max(11, size * 16 / 36))
    }

    /// Собирает кнопки по текущему списку. Лишние разделы библиотеки с полосы уходят.
    private func syncRail() {
        let slots = SectionBoard.order
        let ids = Set(slots.map(\.id))
        for button in railButtons where !ids.contains(button.slotID) {
            button.removeFromSuperview()
            buttonTargets.removeValue(forKey: button.slotID)
        }
        railButtons.removeAll { !ids.contains($0.slotID) }
        for slot in slots {
            if let button = railButtons.first(where: { $0.slotID == slot.id }) {
                button.retitle(slot)
                continue
            }
            let button = SectionRailButton(slot: slot)
            sectionRail.addSubview(button)
            railButtons.append(button)
        }
        for id in Array(bodies.keys) where IslandSection(slotID: id) == nil && !ids.contains(id) {
            bodies[id]?.removeFromSuperview()
            bodies.removeValue(forKey: id)
        }
        wireRailButtons()
    }

    /// Иконки разделов доезжают сами: системный аниматор у утки не тикает.
    private func kickButtonMotion() {
        guard buttonMotion == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.stepButtons(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        buttonMotion = timer
    }

    private func stepButtons(_ timer: Timer) {
        var moving = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for button in railButtons {
            guard let target = buttonTargets[button.slotID] else { continue }
            let dy = target.origin.y - button.frame.origin.y
            if abs(dy) > 0.4 {
                var frame = button.frame
                frame.origin.y += dy * 0.22
                button.frame = frame
                moving = true
            } else {
                button.frame = target
            }
        }
        CATransaction.commit()
        guard !moving else { return }
        timer.invalidate()
        buttonMotion = nil
    }

    func bindActions(target: AnyObject, action: Selector) {
        clickTarget = target
        clickAction = action
        wireRailButtons()
    }

    /// Вешает уже известную цель на кнопки, в том числе появившиеся после запуска.
    private func wireRailButtons() {
        guard let clickAction else { return }
        for button in railButtons {
            button.target = clickTarget
            button.action = clickAction
        }
    }

    func show(on screen: NSScreen) {
        let target = frame(on: screen)
        if window.isVisible && roughly(window.frame, target) && slideTimer == nil { return }
        let tucked = CGRect(x: target.minX, y: screen.frame.maxY, width: target.width, height: 0)
        resting = target
        window.alphaValue = 1
        if !window.isVisible {
            window.setFrame(tucked, display: false)
            pinResting()
            root.setReveal(0)
            window.orderFrontRegardless()
        } else {
            pinResting()
            root.setReveal(window.frame.height)
        }
        slide(from: window.frame, to: target, orderOut: false)
    }

    func hide() {
        sourcesOpen = false
        sourceDrop.close()
        soundStrip.setSourcesOpen(false)
        guard window.isVisible else { return }
        let frame = window.frame
        let top = (window.screen ?? NSScreen.main)?.frame.maxY ?? frame.maxY
        let tucked = CGRect(x: resting.minX, y: top, width: resting.width, height: 0)
        slide(from: frame, to: tucked, orderOut: true)
    }

    /// Сразу убрать окно, без выезда. Иначе жест снимка попадает в островок.
    func dismiss() {
        sourcesOpen = false
        sourceDrop.close()
        soundStrip.setSourcesOpen(false)
        slideTimer?.invalidate()
        slideTimer = nil
        window.orderOut(nil)
    }

    /// Капля от кромки: верх на месте, растёт высота. Аниматор окна у неактивного агента не тикает, поэтому кадры сами.
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
        window.setFrame(frame, display: false)
        pinResting()
        if progress >= 1, !slideOrderOut {
            root.setReveal(nil)
        } else {
            root.setReveal(frame.height)
        }
        window.displayIfNeeded()
        if progress >= 1 {
            timer.invalidate()
            slideTimer = nil
            if slideOrderOut { window.orderOut(nil) }
        }
    }

    /// Корень полного размера: верх у кромки окна, низ обрезает само окно.
    private func pinResting() {
        let full = resting
        guard full.width > 0, full.height > 0 else { return }
        root.frame = NSRect(x: 0, y: host.bounds.height - full.height, width: full.width, height: full.height)
    }

    func select(slotID: String) {
        show(id: slotID)
        if let section = IslandSection(slotID: slotID) {
            onSection?(section)
        }
    }

    /// Щелчок по кнопке полосы. Ядро сообщает наружу, раздел библиотеки только открывает карточку.
    func openSection(_ sender: NSButton) {
        guard let button = sender as? SectionRailButton else { return }
        select(slotID: button.slotID)
    }

    private func show(id: String) {
        currentID = id
        body.subviews.forEach { $0.removeFromSuperview() }
        let view = viewFor(id)
        view.frame = body.bounds
        view.autoresizingMask = [.width, .height]
        body.addSubview(view)
        if let note = view as? NotepadIslandView { note.focusText() }
        for button in railButtons {
            let on = button.slotID == id
            button.contentTintColor = on ? IslandLook.accent : UtkaChrome.dim
        }
    }

    /// Тело ядра уже собрано. Блокнот — своё поле. Остальные разделы библиотеки — тихая карточка.
    private func viewFor(_ id: String) -> NSView {
        if let core = bodies[id], IslandSection(slotID: id) != nil { return core }
        if id == "notepad" { return notepadView() }
        let title = SectionBoard.order.first { $0.id == id }?.listTitle ?? id
        if let card = bodies[id] as? LibrarySectionBody {
            card.setTitle(title)
            return card
        }
        let card = LibrarySectionBody(title: title)
        bodies[id] = card
        return card
    }

    /// Поле блокнота. Черновик живёт, пока утка открыта.
    private func notepadView() -> NotepadIslandView {
        if let view = bodies["notepad"] as? NotepadIslandView { return view }
        let view = NotepadIslandView()
        view.onFile = { [weak self] url, anchor in
            self?.sendNoteToShelf(url, from: anchor)
        }
        bodies["notepad"] = view
        return view
    }

    /// Значок файла летит к кнопке полки, затем файл встаёт на полку и полка открывается.
    private func sendNoteToShelf(_ url: URL, from anchor: NSView) {
        let openShelf = { [weak self] in
            ShotEditor.shelf?.add(urls: [url])
            self?.show(id: IslandSection.shelf.slotID)
        }
        guard let shelfButton = railButtons.first(where: { $0.slotID == IslandSection.shelf.slotID }) else {
            openShelf()
            return
        }
        let flyer = NSImageView()
        flyer.wantsLayer = true
        flyer.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Файл")
        flyer.contentTintColor = UtkaChrome.ink
        flyer.imageScaling = .scaleProportionallyDown
        let size: CGFloat = 18
        let start = anchor.convert(anchor.bounds, to: root)
        let end = shelfButton.convert(shelfButton.bounds, to: root)
        flyer.frame = NSRect(x: start.midX - size / 2, y: start.midY - size / 2, width: size, height: size)
        root.addSubview(flyer)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            flyer.animator().frame = NSRect(x: end.midX - size / 2, y: end.midY - size / 2, width: size, height: size)
            flyer.animator().alphaValue = 0.2
        }, completionHandler: {
            flyer.removeFromSuperview()
            openShelf()
        })
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

/// Кнопка раздела на полосе. id строкой, чтобы рядом с ядром встал раздел библиотеки.
final class SectionRailButton: NSButton {
    let slotID: String
    private var symbolName: String
    private var accessTitle: String
    private var symbolPoint: CGFloat = 0

    init(slot: SectionSlot) {
        slotID = slot.id
        symbolName = slot.symbol
        accessTitle = slot.title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .shadowlessSquare
        imagePosition = .imageOnly
        toolTip = slot.title
        updateSymbol(point: 16)
    }

    required init?(coder: NSCoder) { nil }

    /// Подпись и значок, если карточка каталога сменилась.
    func retitle(_ slot: SectionSlot) {
        symbolName = slot.symbol
        accessTitle = slot.title
        toolTip = slot.title
        symbolPoint = 0
        updateSymbol(point: 16)
    }

    /// Размер значка. Повтор с тем же размером картинку не пересобирает.
    func updateSymbol(point: CGFloat) {
        guard abs(symbolPoint - point) > 0.1 else { return }
        symbolPoint = point
        image = utkaSymbol(symbolName, point: point, label: accessTitle)
    }
}
