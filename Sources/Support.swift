import AppKit
import ImageIO

/// Папка данных утки. В репозиторий не входит.
enum UtkaPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Utka", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Папка снимков. Сюда же полка складывает системные кадры.
    static var shots: URL {
        let dir = support.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Свой файл утки: удаление карточки имеет право стереть его.
    static func ownsShot(_ path: String) -> Bool {
        let root = shots.path
        return path == root || path.hasPrefix(root + "/")
    }
}

/// Картинка, а не документ. Карандаш на карточке только у таких файлов.
func isImageFile(url: URL) -> Bool {
    let images: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"]
    return images.contains(url.pathExtension.lowercased())
}

/// Закладка на файл, чтобы найти его после перезапуска.
enum BookmarkStore {
    static func data(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func url(from data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Живой адрес файла. Если он уже в Корзине, отдаёт копию вне неё: оттуда Мак файл не открывает и не отдаёт на стол.
    static func locate(bookmark: String?, path: String?, name: String) -> URL? {
        if let raw = bookmark, let data = Data(base64Encoded: raw),
           let url = url(from: data),
           let usable = outsideTrash(url) {
            return usable
        }
        if let path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let cached = cachedCopy(named: name)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        return nil
    }

    /// Корзина блокирует и двойной щелчок, и перенос. Копия лежит у утки и ведёт себя как обычный файл.
    private static func outsideTrash(_ url: URL) -> URL? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard isInTrash(url) else { return url }
        let dest = cachedCopy(named: url.lastPathComponent)
        if sameByteCount(url.path, dest.path) { return dest }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = dest.deletingLastPathComponent().appendingPathComponent("." + dest.lastPathComponent + ".part")
        try? FileManager.default.removeItem(at: partial)
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: partial.path)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: partial, to: dest)
            return dest
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
        }
    }

    private static func isInTrash(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    private static func cachedCopy(named name: String) -> URL {
        UtkaPaths.support
            .appendingPathComponent("FromTrash", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func sameByteCount(_ left: String, _ right: String) -> Bool {
        guard FileManager.default.fileExists(atPath: right) else { return false }
        let leftSize = (try? FileManager.default.attributesOfItem(atPath: left)[.size] as? NSNumber)?.intValue
        let rightSize = (try? FileManager.default.attributesOfItem(atPath: right)[.size] as? NSNumber)?.intValue
        return leftSize != nil && leftSize == rightSize
    }
}

/// Вид островка на этом Маке. В git не пишется.
enum IslandLookMode: Int {
    case system
    case light
    case dark
}

enum IslandLook {
    static let changed = Notification.Name("utka.islandLook")
    private static let modeKey = "islandLookMode"
    private static let glassKey = "islandGlass"
    private static let accentKey = "islandAccent"
    private static let strokeKey = "islandStroke"
    private static let strokeColorKey = "islandStrokeColor"

    /// Без ключа остаётся нынешний тёмный вид.
    static var mode: IslandLookMode {
        get {
            guard let raw = UserDefaults.standard.object(forKey: modeKey) as? Int,
                  let mode = IslandLookMode(rawValue: raw) else { return .dark }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
            poke()
        }
    }

    /// 0 — плотная заливка как сейчас, 1 — сквозное матовое стекло.
    static var glass: Double {
        get { min(1, max(0, UserDefaults.standard.double(forKey: glassKey))) }
        set {
            UserDefaults.standard.set(min(1, max(0, newValue)), forKey: glassKey)
            poke()
        }
    }

    /// Выбранное. Без своего цвета совпадает с чернилами темы.
    static var accent: NSColor {
        get { storedColor(accentKey) ?? UtkaChrome.ink }
        set { store(newValue, key: accentKey) }
    }

    private static func storedColor(_ key: String) -> NSColor? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }

    private static func store(_ color: NSColor, key: String) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: rgb, requiringSecureCoding: true) {
            UserDefaults.standard.set(data, forKey: key)
        }
        poke()
    }

    static var hasAccent: Bool { UserDefaults.standard.data(forKey: accentKey) != nil }

    /// Обводка капли. Без ключа выключена.
    static var strokeOn: Bool {
        get { UserDefaults.standard.bool(forKey: strokeKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: strokeKey)
            poke()
        }
    }

    /// Цвет обводки. Без своего цвета совпадает с чернилами темы.
    static var strokeColor: NSColor {
        get { storedColor(strokeColorKey) ?? UtkaChrome.ink }
        set { store(newValue, key: strokeColorKey) }
    }

    static var dark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system:
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        }
    }

    static var appearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Плотная заливка капли. Прозрачность стекла её разбавляет.
    static var veil: NSColor {
        let solid: NSColor = dark ? .black : .white
        return solid.withAlphaComponent(CGFloat(1 - glass))
    }

    static var solid: NSColor { dark ? .black : .white }

    static func poke() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

/// Общие цвета и шрифт. Только системный гротеск.
enum UtkaChrome {
    static var ink: NSColor { IslandLook.dark ? .white : NSColor(calibratedWhite: 0.12, alpha: 1) }
    static var dim: NSColor {
        IslandLook.dark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.45)
    }
    static var card: NSColor {
        IslandLook.dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.06)
    }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font(size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    /// Окно берёт текущий вид и перекрашивается в тот же момент, что и островок. Токен снять при закрытии.
    static func track(_ window: NSWindow, repaint: @escaping () -> Void) -> NSObjectProtocol {
        let apply = { [weak window] in
            window?.appearance = IslandLook.appearance
            repaint()
        }
        apply()
        return NotificationCenter.default.addObserver(
            forName: IslandLook.changed,
            object: nil,
            queue: nil
        ) { _ in
            apply()
        }
    }
}

/// Фон окна: стекло и вуаль капли. Сам перекрашивается при смене темы.
final class UtkaPanelChrome: NSVisualEffectView {
    private static let radius: CGFloat = 14
    private let veil = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        maskImage = Self.roundedMask(radius: Self.radius)
        veil.wantsLayer = true
        veil.layer?.cornerRadius = Self.radius
        addSubview(veil)
        NotificationCenter.default.addObserver(self, selector: #selector(apply), name: IslandLook.changed, object: nil)
        apply()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        veil.frame = bounds
        if subviews.first !== veil {
            addSubview(veil, positioned: .below, relativeTo: nil)
        }
        window?.invalidateShadow()
    }

    /// Скругление для самого стекла. Без маски размытие за окном и тень остаются квадратными — видна рамка.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Материал и плотность вуали как у капли.
    @objc func apply() {
        material = IslandLook.dark ? .hudWindow : .menu
        appearance = IslandLook.appearance
        window?.appearance = IslandLook.appearance
        veil.layer?.backgroundColor = IslandLook.veil.cgColor
    }
}

/// Документ списка, ноль сверху.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Прокрутка, которая не прижимает список к низу.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Превью картинки или иконка файла.
func filePreview(url: URL, maxPixel: CGFloat) -> NSImage {
    if isImageFile(url: url), let thumb = thumbnail(url: url, maxPixel: maxPixel) {
        return thumb
    }
    return NSWorkspace.shared.icon(forFile: url.path)
}

/// Уменьшенная копия изображения с диска.
func thumbnail(url: URL, maxPixel: CGFloat) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Короткая строка для списка.
func oneLine(_ text: String, limit: Int = 80) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)) + "…"
}

/// Тень на время перетаскивания. Ноль — карточка снова лежит в слоте.
func utkaLift(_ view: NSView, _ amount: CGFloat) {
    let radius = view.layer?.cornerRadius ?? 8
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    view.layer?.shadowColor = NSColor.black.cgColor
    view.layer?.shadowOpacity = Float(0.32 * amount)
    view.layer?.shadowRadius = 12 * amount
    view.layer?.shadowOffset = CGSize(width: 0, height: -4 * amount)
    view.layer?.shadowPath = CGPath(
        roundedRect: view.bounds,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    CATransaction.commit()
}

final class FileCardView: NSView, NSDraggingSource {
    var fileURL: URL?
    var consumeOnDrop = false
    var onRemove: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onEdit: (() -> Void)? { didSet { updatePencil() } }
    /// Закрепы: внутри островка карточка меняется местами с соседями, за краем островка уносит файл наружу.
    /// У полки выключено: там драг сразу уносит файл в другое приложение.
    var canReorder = false { didSet { window?.invalidateCursorRects(for: self) } }
    var onReorderDrag: ((NSPoint) -> Void)?
    var onReorderDrop: (() -> Void)?
    /// Полка: драг начался, это имя нельзя сразу забирать со стола.
    var onExportBegan: ((String) -> Void)?
    /// Полка: драг отменён, защиту имени можно снять.
    var onExportCancel: ((String) -> Void)?
    /// Полка: дроп удался. Карточка уходит, файл стирается, когда получатель его отпустил.
    var onConsume: (() -> Void)?
    /// Отпускание над полкой — файл просто вернули. Карточку не снимаем.
    var cardStaysOnDrop: ((NSPoint) -> Bool)?

    private let iconView = NSImageView()
    private let nameLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let removeButton = NSButton()
    private let editButton = NSButton()
    private var didDrag = false
    private var reorderMoved = false
    private var reorderGrab = NSPoint.zero
    private var pressPoint = NSPoint.zero
    private var dragName: String?
    private var lastClickAt = Date.distantPast
    private var lastClickPoint = NSPoint.zero
    private var showsPicture = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = UtkaChrome.card.cgColor
        layer?.cornerRadius = 10
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        removeButton.title = "×"
        removeButton.isBordered = false
        removeButton.font = UtkaChrome.font(14, weight: .medium)
        removeButton.contentTintColor = UtkaChrome.dim
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        editButton.isBordered = false
        editButton.imagePosition = .imageOnly
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Пометить")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        editButton.contentTintColor = UtkaChrome.ink
        editButton.toolTip = "Пометить"
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.isHidden = true
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(removeButton)
        addSubview(editButton)
        NotificationCenter.default.addObserver(self, selector: #selector(retintCard), name: IslandLook.changed, object: nil)
        retintCard()
    }

    /// Подтягивает карточку под текущий вид островка.
    @objc private func retintCard() {
        layer?.backgroundColor = UtkaChrome.card.cgColor
        nameLabel.textColor = UtkaChrome.dim
        removeButton.contentTintColor = UtkaChrome.dim
        editButton.contentTintColor = UtkaChrome.ink
    }

    /// Поднимает карточку, пока её тащат по сетке.
    func setLift(_ amount: CGFloat) {
        utkaLift(self, amount)
    }

    required init?(coder: NSCoder) { nil }

    /// Показывает файл. Если его уже нет на диске, карточка остаётся с именем.
    func show(url: URL?, title: String) {
        fileURL = url
        nameLabel.stringValue = title
        showsPicture = false
        if let url, isImageFile(url: url), let thumb = thumbnail(url: url, maxPixel: 160) {
            iconView.image = thumb
            showsPicture = true
        } else if let url {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }
        toolTip = title
        updatePencil()
    }

    /// Карандаш только на живой картинке, у которой есть куда открыть редактор.
    private func updatePencil() {
        editButton.isHidden = onEdit == nil || !showsPicture
    }

    override func layout() {
        super.layout()
        let labelH: CGFloat = 18
        nameLabel.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: labelH)
        iconView.frame = NSRect(x: 18, y: labelH + 8, width: bounds.width - 36, height: max(12, bounds.height - labelH - 28))
        removeButton.frame = NSRect(x: bounds.width - 22, y: bounds.height - 20, width: 18, height: 18)
        editButton.frame = NSRect(x: 4, y: bounds.height - 20, width: 18, height: 18)
    }

    override func resetCursorRects() {
        guard canReorder else { return }
        addCursorRect(bounds, cursor: .openHand)
        for button in [removeButton, editButton] where !button.isHidden {
            addCursorRect(button.frame, cursor: .arrow)
        }
    }

    /// Щелчок по превью и имени идёт в карточку. Крестик и карандаш остаются кнопками.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === removeButton || hit === editButton { return hit }
        if hit.isDescendant(of: removeButton) || hit.isDescendant(of: editButton) { return hit }
        return self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        reorderMoved = false
        reorderGrab = NSPoint(x: local.x, y: bounds.height - local.y)
        pressPoint = local
        didDrag = false
        let now = Date()
        let near = hypot(event.locationInWindow.x - lastClickPoint.x, event.locationInWindow.y - lastClickPoint.y) < 6
        let quick = now.timeIntervalSince(lastClickAt) <= NSEvent.doubleClickInterval
        if event.clickCount >= 2 || (near && quick) {
            lastClickAt = .distantPast
            openFile()
            return
        }
        lastClickAt = now
        lastClickPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        if canReorder {
            dragReorder(with: event)
            return
        }
        beginExport(with: event)
    }

    /// Файл уезжает в другое приложение тем же жестом, что и с полки.
    private func beginExport(with event: NSEvent) {
        guard !didDrag, let url = fileURL else { return }
        didDrag = true
        dragName = url.lastPathComponent
        onExportBegan?(url.lastPathComponent)
        onDrag?(true)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 48, height: 48), contents: iconView.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
        didDrag = false
        let name = dragName
        dragName = nil
        // Удачный перенос без снятия карточки — не отмена: имя на столе остаётся под защитой,
        // иначе копия возвращается на полку вторым снимком. Отпускание над полкой — тоже отмена.
        let returned = cardStaysOnDrop?(screenPoint) ?? false
        guard !operation.isEmpty, !returned else {
            if let name { onExportCancel?(name) }
            return
        }
        if consumeOnDrop { onConsume?() }
    }

    override func mouseUp(with event: NSEvent) {
        guard reorderMoved else { return }
        reorderMoved = false
        NSCursor.pop()
        onReorderDrop?()
    }

    /// Тащит карточку по сетке. Мелкая дрожь руки при щелчке перестановкой не считается.
    /// Курсор ушёл за край островка — карточка встаёт на место, а наружу едет файл.
    private func dragReorder(with event: NSEvent) {
        guard let parent = superview else { return }
        if !reorderMoved {
            let local = convert(event.locationInWindow, from: nil)
            guard hypot(local.x - pressPoint.x, local.y - pressPoint.y) > 4 else { return }
            reorderMoved = true
            lastClickAt = .distantPast
            NSCursor.closedHand.push()
        }
        if leftWindow(event), fileURL != nil {
            reorderMoved = false
            NSCursor.pop()
            onReorderDrop?()
            beginExport(with: event)
            return
        }
        let point = parent.convert(event.locationInWindow, from: nil)
        onReorderDrag?(NSPoint(x: point.x - reorderGrab.x, y: point.y - reorderGrab.y))
    }

    /// Курсор за пределами окна островка.
    private func leftWindow(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        return !content.bounds.contains(point)
    }

    /// Открывает файл той программой, которую Мак выбрал для этого типа. PDF — как обычный PDF.
    private func openFile() {
        guard let url = fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func removeTapped() {
        onRemove?()
    }

    @objc private func editTapped() {
        onEdit?()
    }
}

/// Текст заметки: выделение мышью держит островок открытым, пока кнопка зажата.
final class SelectableTextView: NSTextView {
    var onSelecting: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelecting?(true)
        super.mouseDown(with: event)
        onSelecting?(false)
    }
}

/// Строка текста: клик по строке или иконка копирует всё, шеврон раскрывает текст для частичного копирования.
/// В закрепах строку перетаскивают целиком, как раздел в настройках.
final class TextRowView: NSView {
    static let collapsedHeight: CGFloat = 48
    static let expandedHeight: CGFloat = 172

    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?
    var onToggle: (() -> Void)?
    var onAlarmPicked: ((Date?) -> Void)?
    /// Захват порядка. У буфера выключено, строка остаётся прежней.
    var canReorder = false { didSet { refreshGrip() } }
    var onReorderDrag: ((CGFloat) -> Void)?
    var onReorderDrop: (() -> Void)?
    var onCopySelection: ((String) -> Void)?
    var onSelecting: ((Bool) -> Void)?
    /// Сохранили правку: название и текст уже без пробелов по краям.
    var onEdited: ((String, String) -> Void)? { didSet { applyEditVisibility() } }
    /// Правку закончили, сохранением или отменой.
    var onEditEnded: (() -> Void)?
    /// Идёт правка. Пока она идёт, список заметок не пересобирается.
    var isEditing: Bool { editing }
    var isExpanded = false {
        didSet {
            guard isExpanded != oldValue else { return }
            updateExpanded()
        }
    }

    private let titleLabel = UtkaChrome.label("", size: 13, weight: .semibold)
    private let detailLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let deleteButton = NSButton()
    private let copyButton = NSButton()
    private let alarmButton = NSButton()
    private let expandButton = NSButton()
    private var hasAlarm = false
    private var alarmRinging = false
    private var currentDueAt: Date?
    private let alarmPopover = AlarmPopover()
    private let selectionButton = NSButton()
    private var reorderArmed = false
    private var reorderMoved = false
    private var reorderGrab: CGFloat = 0
    private var pressPoint = NSPoint.zero
    private let collapseButton = NSButton()
    private let editButton = NSButton()
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private let titleField = NSTextField()
    private var editing = false
    private var shownTitle = ""
    private var shownBody = ""
    private let textScroll = NSScrollView()
    private let textView = SelectableTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = UtkaChrome.card.cgColor
        layer?.cornerRadius = 8
        deleteButton.title = "×"
        deleteButton.isBordered = false
        deleteButton.font = UtkaChrome.font(14, weight: .medium)
        deleteButton.contentTintColor = UtkaChrome.dim
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        styleIcon(copyButton, symbol: "doc.on.doc", tip: "Копировать всё", action: #selector(copyTapped))
        styleIcon(alarmButton, symbol: "calendar", tip: "Поставить будильник", action: #selector(alarmTapped))
        styleIcon(expandButton, symbol: "chevron.down", tip: "Раскрыть", action: #selector(toggleTapped))
        selectionButton.title = "Копировать выделенное"
        selectionButton.bezelStyle = .rounded
        selectionButton.controlSize = .small
        selectionButton.target = self
        selectionButton.action = #selector(copySelectionTapped)
        collapseButton.title = "Свернуть"
        collapseButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Свернуть")
        collapseButton.imagePosition = .imageLeading
        collapseButton.bezelStyle = .rounded
        collapseButton.controlSize = .small
        collapseButton.target = self
        collapseButton.action = #selector(toggleTapped)
        styleFooter(editButton, title: "Изменить", symbol: "pencil", action: #selector(editTapped))
        styleFooter(saveButton, title: "Сохранить", symbol: "checkmark", action: #selector(saveEditTapped))
        styleFooter(cancelButton, title: "Отмена", symbol: nil, action: #selector(cancelEditTapped))
        titleField.font = UtkaChrome.font(13, weight: .semibold)
        titleField.placeholderString = "Название"
        titleField.isBordered = false
        titleField.focusRingType = .none
        titleField.bezelStyle = .roundedBezel
        titleField.isHidden = true
        // Выделение мышью держит островок открытым; во время правки его не отпускаем.
        textView.onSelecting = { [weak self] on in
            guard let self else { return }
            if self.editing, !on { return }
            self.onSelecting?(on)
        }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = UtkaChrome.font(12)
        textView.textColor = UtkaChrome.ink
        textView.insertionPointColor = UtkaChrome.ink
        textView.selectedTextAttributes = [.backgroundColor: UtkaChrome.dim]
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.autohidesScrollers = true
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(copyButton)
        addSubview(alarmButton)
        addSubview(expandButton)
        addSubview(deleteButton)
        addSubview(textScroll)
        addSubview(selectionButton)
        addSubview(collapseButton)
        addSubview(editButton)
        addSubview(saveButton)
        addSubview(cancelButton)
        addSubview(titleField)
        NotificationCenter.default.addObserver(self, selector: #selector(retintRow), name: IslandLook.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quackerChanged), name: QuackerPrefs.changed, object: nil)
        updateExpanded()
        retintRow()
        applyAlarmVisibility()
    }

    /// Крякер выключили — кнопку будильника убрать, место не оставлять.
    @objc private func quackerChanged() {
        applyAlarmVisibility()
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    /// Кнопка будильника только при включённом крякере.
    private func applyAlarmVisibility() {
        alarmButton.isHidden = !QuackerPrefs.enabled
    }

    /// Текст и карточка строки читаются и в светлом виде.
    @objc private func retintRow() {
        layer?.backgroundColor = UtkaChrome.card.cgColor
        titleLabel.textColor = UtkaChrome.ink
        detailLabel.textColor = UtkaChrome.dim
        deleteButton.contentTintColor = UtkaChrome.dim
        copyButton.contentTintColor = UtkaChrome.dim
        expandButton.contentTintColor = isExpanded ? UtkaChrome.ink : UtkaChrome.dim
        textView.textColor = UtkaChrome.ink
        textView.insertionPointColor = UtkaChrome.ink
        textView.selectedTextAttributes = [.backgroundColor: UtkaChrome.dim]
        updateAlarmLook()
    }

    required init?(coder: NSCoder) { nil }

    /// dueAt — будильник заметки, если стоит; вместо превью текста показывается дата.
    /// ringing — срок уже наступил и заметку ещё не открывали: подсвечивает строку.
    func show(title: String, detail: String, body: String = "", dueAt: Date? = nil, ringing: Bool = false) {
        titleLabel.stringValue = title
        shownTitle = title
        shownBody = body
        hasAlarm = dueAt != nil
        alarmRinging = ringing
        currentDueAt = dueAt
        let alarmText = dueAt.map(alarmLabel)
        detailLabel.stringValue = alarmText ?? detail
        detailLabel.isHidden = isExpanded || detailLabel.stringValue.isEmpty || (alarmText == nil && detail == title)
        textView.string = body
        updateAlarmLook()
    }

    private func updateAlarmLook() {
        let symbol = hasAlarm ? "calendar.badge.clock" : "calendar"
        alarmButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Будильник")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        alarmButton.toolTip = hasAlarm ? "Изменить будильник" : "Поставить будильник"
        alarmButton.contentTintColor = alarmRinging ? .systemRed : (hasAlarm ? UtkaChrome.ink : UtkaChrome.dim)
        detailLabel.textColor = alarmRinging ? .systemRed : UtkaChrome.dim
        layer?.borderWidth = alarmRinging ? 1.5 : 0
        layer?.borderColor = alarmRinging ? NSColor.systemRed.cgColor : nil
    }

    private func styleIcon(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.title = ""
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = UtkaChrome.dim
        button.toolTip = tip
        button.target = self
        button.action = action
    }

    private func updateExpanded() {
        let symbol = isExpanded ? "chevron.up" : "chevron.down"
        expandButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        expandButton.toolTip = isExpanded ? "Свернуть" : "Раскрыть"
        textScroll.isHidden = !isExpanded
        selectionButton.isHidden = !isExpanded
        collapseButton.isHidden = !isExpanded
        expandButton.contentTintColor = isExpanded ? UtkaChrome.ink : UtkaChrome.dim
        detailLabel.isHidden = isExpanded || detailLabel.stringValue.isEmpty || detailLabel.stringValue == titleLabel.stringValue
        applyEditVisibility()
        needsLayout = true
    }

    /// Рука захвата только у закреп, где строк больше одной.
    private func refreshGrip() {
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    /// Поднимает строку, пока её тащат.
    func setLift(_ amount: CGFloat) {
        utkaLift(self, amount)
    }

    override func layout() {
        super.layout()
        let head = TextRowView.collapsedHeight
        let top = bounds.height - head
        let mid = top + (head - 18) / 2
        let showAlarm = QuackerPrefs.enabled
        alarmButton.isHidden = !showAlarm
        deleteButton.frame = NSRect(x: bounds.width - 28, y: mid, width: 22, height: 18)
        expandButton.frame = NSRect(x: bounds.width - 54, y: mid, width: 22, height: 18)
        copyButton.frame = NSRect(x: bounds.width - 80, y: mid, width: 22, height: 18)
        var trail: CGFloat = 96
        if showAlarm {
            alarmButton.frame = NSRect(x: bounds.width - 106, y: mid, width: 22, height: 18)
            trail = 122
        }
        let textW = bounds.width - trail
        if isExpanded || detailLabel.isHidden {
            titleLabel.frame = NSRect(x: 10, y: top + (head - 18) / 2, width: textW, height: 18)
        } else {
            titleLabel.frame = NSRect(x: 10, y: top + head - 24, width: textW, height: 16)
            detailLabel.frame = NSRect(x: 10, y: top + 6, width: textW, height: 14)
        }
        if isExpanded {
            selectionButton.frame = NSRect(x: 10, y: 6, width: 150, height: 22)
            collapseButton.frame = NSRect(x: bounds.width - 100, y: 6, width: 90, height: 22)
            textScroll.frame = NSRect(x: 8, y: 34, width: bounds.width - 16, height: max(20, top - 38))
            editButton.frame = NSRect(x: 168, y: 6, width: 96, height: 22)
            saveButton.frame = NSRect(x: 10, y: 6, width: 112, height: 22)
            cancelButton.frame = NSRect(x: 130, y: 6, width: 90, height: 22)
            titleField.frame = NSRect(x: 8, y: top + (head - 24) / 2, width: max(60, textW), height: 24)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let controls = [deleteButton, copyButton, expandButton, alarmButton]
        for button in controls where !button.isHidden {
            addCursorRect(button.frame, cursor: .arrow)
        }
        guard canReorder, !isExpanded else { return }
        let dragEnd = (controls.filter { !$0.isHidden }.map(\.frame.minX).min() ?? bounds.width) - 4
        let drag = NSRect(x: 0, y: bounds.height - TextRowView.collapsedHeight, width: max(0, dragEnd), height: TextRowView.collapsedHeight)
        addCursorRect(drag, cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard canReorder, !isExpanded else { return hit }
        let controls = [deleteButton, copyButton, expandButton, alarmButton]
        if controls.contains(where: { hit === $0 || hit.isDescendant(of: $0) }) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        reorderMoved = false
        reorderArmed = canReorder && !isExpanded && local.y >= bounds.height - TextRowView.collapsedHeight
        pressPoint = local
        reorderGrab = bounds.height - local.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard reorderArmed, let parent = superview else { return }
        let local = convert(event.locationInWindow, from: nil)
        if !reorderMoved {
            guard hypot(local.x - pressPoint.x, local.y - pressPoint.y) > 4 else { return }
            reorderMoved = true
            NSCursor.closedHand.push()
        }
        let point = parent.convert(event.locationInWindow, from: nil)
        onReorderDrag?(point.y - reorderGrab)
    }

    override func mouseUp(with event: NSEvent) {
        if reorderMoved {
            reorderMoved = false
            reorderArmed = false
            NSCursor.pop()
            onReorderDrop?()
            return
        }
        reorderArmed = false
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), point.y >= bounds.height - TextRowView.collapsedHeight else { return }
        let controls = [deleteButton, copyButton, expandButton, alarmButton]
        guard !controls.contains(where: { !$0.isHidden && $0.frame.contains(point) }) else { return }
        flash()
        onClick?()
    }

    private func flash() {
        layer?.backgroundColor = UtkaChrome.ink.withAlphaComponent(0.2).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.layer?.backgroundColor = UtkaChrome.card.cgColor
        }
    }

    @objc private func copyTapped() {
        flash()
        onClick?()
    }

    @objc private func toggleTapped() {
        guard !editing else { return }
        onToggle?()
    }

    private func styleFooter(_ button: NSButton, title: String, symbol: String?, action: Selector) {
        button.title = title
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    /// Какие кнопки внизу и вверху видны сейчас: обычные или «Сохранить»/«Отмена».
    private func applyEditVisibility() {
        let normal = isExpanded && !editing
        selectionButton.isHidden = !normal
        collapseButton.isHidden = !normal
        // «Изменить» только там, где правку принимают (заметки), не в буфере.
        editButton.isHidden = !normal || onEdited == nil
        saveButton.isHidden = !(isExpanded && editing)
        cancelButton.isHidden = !(isExpanded && editing)
        titleField.isHidden = !(isExpanded && editing)
        titleLabel.isHidden = isExpanded && editing
        // Пока правят, строку нельзя ни свернуть, ни удалить, ни переставить:
        // список в это время не пересобирается и правка не должна потеряться.
        for button in [deleteButton, copyButton, expandButton, alarmButton] {
            button.isEnabled = !editing
            button.alphaValue = editing ? 0.35 : 1
        }
    }

    @objc private func editTapped() {
        guard isExpanded, !editing else { return }
        editing = true
        titleField.stringValue = shownTitle
        titleField.textColor = UtkaChrome.ink
        // Видимая подложка: иначе не понять, что поля стали редактируемыми.
        let tint = UtkaChrome.ink.withAlphaComponent(0.16)
        titleField.backgroundColor = tint
        titleField.drawsBackground = true
        textScroll.wantsLayer = true
        textScroll.layer?.backgroundColor = tint.cgColor
        textScroll.layer?.cornerRadius = 6
        textView.isEditable = true
        textView.string = shownBody
        applyEditVisibility()
        needsLayout = true
        onSelecting?(true)
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (shownBody as NSString).length, length: 0))
    }

    @objc private func saveEditTapped() {
        guard editing else { return }
        let body = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Пустую заметку не сохраняем: проще оставить как была, чем потерять текст.
        guard !body.isEmpty else {
            NSSound.beep()
            return
        }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finishEditing()
        onEdited?(title, body)
        onEditEnded?()
    }

    @objc private func cancelEditTapped() {
        guard editing else { return }
        textView.string = shownBody
        titleField.stringValue = shownTitle
        finishEditing()
        onEditEnded?()
    }

    private func finishEditing() {
        editing = false
        textScroll.layer?.backgroundColor = nil
        textView.isEditable = false
        window?.makeFirstResponder(nil)
        applyEditVisibility()
        needsLayout = true
        onSelecting?(false)
    }

    deinit {
        // Строку пересобрали, пока её правили: островок больше не держим.
        if editing { onSelecting?(false) }
    }

    @objc private func alarmTapped() {
        alarmPopover.onPresenting = { [weak self] active in self?.onSelecting?(active) }
        alarmPopover.show(from: alarmButton, initial: currentDueAt) { [weak self] date in
            self?.onAlarmPicked?(date)
        }
    }

    @objc private func copySelectionTapped() {
        let range = textView.selectedRange()
        let text = textView.string as NSString
        let piece = range.length > 0 ? text.substring(with: range) : text as String
        flash()
        onCopySelection?(piece)
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

/// Марка в панели: рисуется целиком, без уменьшения в крошечный квадрат.
final class DuckMarkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: IslandLook.changed, object: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        guard !IslandLook.dark else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSColor.black.setFill()
        bounds.fill(using: .sourceAtop)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    /// На светлой капле белая утка становится чёрной.
    @objc private func lookChanged() {
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }
}

/// Силуэт марки для строки меню: система сама красит его под тему.
enum MenuMark {
    /// Белая утка без чёрного квадрата, в полном размере исходника.
    static func cutout(from image: NSImage) -> NSImage {
        let side = 512
        guard let canvas = bitmap(side, side) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let box = inkBox(canvas), let cropped = cropInk(canvas, box: box, smooth: true) else { return image }
        let duck = NSImage(size: NSSize(width: cropped.pixelsWide, height: cropped.pixelsHigh))
        duck.addRepresentation(cropped)
        return duck
    }

    static func template(from image: NSImage) -> NSImage {
        let duck = cutout(from: image)
        let result = NSImage(size: NSSize(width: 18, height: 18))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        duck.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
        result.unlockFocus()
        result.isTemplate = true
        return result
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func bitmap(_ width: Int, _ height: Int) -> NSBitmapImageRep? {
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

    /// Прямоугольник белых штрихов. Ноль строки — верх буфера.
    private static func inkBox(_ rep: NSBitmapImageRep) -> (Int, Int, Int, Int)? {
        guard let data = rep.bitmapData else { return nil }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        let bpr = rep.bytesPerRow
        var minX = w, minY = h, maxX = 0, maxY = 0
        var found = false
        for y in 0..<h {
            for x in 0..<w {
                let i = y * bpr + x * 4
                let sum = Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])
                if sum > 500 {
                    found = true
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }
        guard found else { return nil }
        return (minX, minY, maxX, maxY)
    }

    private static func cropInk(_ source: NSBitmapImageRep, box: (Int, Int, Int, Int), smooth: Bool = false) -> NSBitmapImageRep? {
        let pad = 6
        let minX = max(0, box.0 - pad)
        let minY = max(0, box.1 - pad)
        let maxX = min(source.pixelsWide - 1, box.2 + pad)
        let maxY = min(source.pixelsHigh - 1, box.3 + pad)
        let w = maxX - minX + 1
        let h = maxY - minY + 1
        guard w > 2, h > 2, let out = bitmap(w, h), let src = source.bitmapData, let dst = out.bitmapData else { return nil }
        let sbpr = source.bytesPerRow
        let dbpr = out.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let si = (minY + y) * sbpr + (minX + x) * 4
                let di = y * dbpr + x * 4
                let lum = (Int(src[si]) + Int(src[si + 1]) + Int(src[si + 2])) / 3
                let alpha = smooth ? lum : (lum > 170 ? 255 : 0)
                dst[di] = 255
                dst[di + 1] = 255
                dst[di + 2] = 255
                dst[di + 3] = UInt8(alpha)
            }
        }
        return out
    }
}
