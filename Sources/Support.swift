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
}

/// Общие цвета и шрифт. Только системный гротеск.
enum UtkaChrome {
    static let ink = NSColor.white
    static let dim = NSColor.white.withAlphaComponent(0.55)
    static let card = NSColor.white.withAlphaComponent(0.08)

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
    let ext = url.pathExtension.lowercased()
    let images: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"]
    if images.contains(ext), let thumb = thumbnail(url: url, maxPixel: maxPixel) {
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

/// Карточка файла: превью, имя, вытаскивание наружу.
final class FileCardView: NSView, NSDraggingSource {
    var fileURL: URL?
    var consumeOnDrop = false
    var onRemove: (() -> Void)?
    var onDrag: ((Bool) -> Void)?

    private let iconView = NSImageView()
    private let nameLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let removeButton = NSButton()
    private var didDrag = false

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
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(removeButton)
    }

    required init?(coder: NSCoder) { nil }

    /// Показывает файл. Если его уже нет на диске, карточка остаётся с именем.
    func show(url: URL?, title: String) {
        fileURL = url
        nameLabel.stringValue = title
        if let url {
            iconView.image = filePreview(url: url, maxPixel: 160)
        } else {
            iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }
        toolTip = title
    }

    override func layout() {
        super.layout()
        let labelH: CGFloat = 18
        nameLabel.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: labelH)
        iconView.frame = NSRect(x: 18, y: labelH + 8, width: bounds.width - 36, height: bounds.height - labelH - 28)
        removeButton.frame = NSRect(x: bounds.width - 22, y: bounds.height - 20, width: 18, height: 18)
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let url = fileURL else { return }
        didDrag = true
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
        if consumeOnDrop && !operation.isEmpty {
            onRemove?()
        }
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}

/// Строка текста: клик копирует, крестик убирает запись.
final class TextRowView: NSView {
    var onClick: (() -> Void)?
    var onDelete: (() -> Void)?
    private let titleLabel = UtkaChrome.label("", size: 13, weight: .semibold)
    private let detailLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let deleteButton = NSButton()

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
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { nil }

    func show(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty || detail == title
    }

    override func layout() {
        super.layout()
        deleteButton.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 18) / 2, width: 22, height: 18)
        let textW = bounds.width - 44
        if detailLabel.isHidden {
            titleLabel.frame = NSRect(x: 10, y: (bounds.height - 18) / 2, width: textW, height: 18)
        } else {
            titleLabel.frame = NSRect(x: 10, y: bounds.height - 24, width: textW, height: 16)
            detailLabel.frame = NSRect(x: 10, y: 6, width: textW, height: 14)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !deleteButton.frame.contains(point) else { return }
        flash()
        onClick?()
    }

    private func flash() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.layer?.backgroundColor = UtkaChrome.card.cgColor
        }
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

/// Марка в панели: рисуется целиком, без уменьшения в крошечный квадрат.
final class DuckMarkView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
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
