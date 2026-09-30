import AppKit

/// Файл блокнота на диске. Полка получает уже готовый путь.
enum NoteFile {
    /// Каталог `~/Library/Application Support/UtkaNotepad`.
    static func folder() throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("UtkaNotepad", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Имя без пути и без хвоста `.txt`. Пустое имя сохранять нельзя.
    static func cleanName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".txt") {
            text = String(text.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let forbidden = CharacterSet(charactersIn: "/:\u{0}")
        text = text.components(separatedBy: forbidden).joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "." || text == ".." { return "" }
        if text.count > 80 { text = String(text.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
    }

    /// Свободный путь. Занятое имя получает номер, старый файл остаётся.
    static func uniqueURL(name: String, in folder: URL) -> URL {
        let manager = FileManager.default
        let first = folder.appendingPathComponent(name).appendingPathExtension("txt")
        if !manager.fileExists(atPath: first.path) { return first }
        var number = 2
        while true {
            let next = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension("txt")
            if !manager.fileExists(atPath: next.path) { return next }
            number += 1
        }
    }

    /// Пишет текст в новый `.txt`.
    static func write(text: String, name: String) throws -> URL {
        let folder = try folder()
        let url = uniqueURL(name: name, in: folder)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Тело раздела «Блокнот» на островке: текст и полоса «Название» / поле / «Сохранить».
final class NotepadIslandView: NSView {
    var onFile: ((URL, NSView) -> Void)?
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let bar = NSView()
    private let nameLabel = UtkaChrome.label("Название", size: 13, weight: .medium)
    private let nameField = NSTextField()
    private let saveButton = NSButton()
    private var lookObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepareText()
        prepareBar()
        applyLook()
        lookObserver = NotificationCenter.default.addObserver(
            forName: IslandLook.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyLook()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let lookObserver {
            NotificationCenter.default.removeObserver(lookObserver)
        }
    }

    /// Курсор в текст заметки.
    func focusText() {
        guard let window, window.firstResponder !== textView, window.firstResponder !== nameField.currentEditor() else { return }
        window.makeFirstResponder(textView)
    }

    /// Цвета полосы под тему островка.
    func applyLook() {
        textView.textColor = UtkaChrome.ink
        textView.insertionPointColor = UtkaChrome.ink
        textView.font = UtkaChrome.font(14)
        nameLabel.textColor = UtkaChrome.ink
        nameField.textColor = UtkaChrome.ink
        nameField.font = UtkaChrome.font(13)
        saveButton.font = UtkaChrome.font(13, weight: .medium)
    }

    /// Текстовое поле над полосой. Скролл появляется, когда текст выше тела.
    private func prepareText() {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        addSubview(scroll)
    }

    /// Внизу сразу подпись, поле имени и одна кнопка. Отдельного окна нет.
    private func prepareBar() {
        nameField.font = UtkaChrome.font(13)
        nameField.textColor = UtkaChrome.ink
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.focusRingType = .default
        nameField.target = self
        nameField.action = #selector(saveClicked)
        saveButton.title = "Сохранить .txt"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        bar.addSubview(nameLabel)
        bar.addSubview(nameField)
        bar.addSubview(saveButton)
        addSubview(bar)
    }

    override func layout() {
        super.layout()
        layoutNote()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutNote()
    }

    /// Полоса внизу: «Название», поле, «Сохранить». Текст над ней.
    private func layoutNote() {
        let barHeight: CGFloat = 36
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        scroll.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: max(24, bounds.height - barHeight))
        let width = max(40, scroll.contentSize.width)
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if textView.frame.width != width { textView.frame.size.width = width }
        nameLabel.sizeToFit()
        var label = nameLabel.frame.size
        if label.width < 8 { label = NSSize(width: 72, height: 16) }
        nameLabel.frame = NSRect(x: 0, y: (barHeight - label.height) / 2, width: label.width, height: label.height)
        saveButton.sizeToFit()
        var button = saveButton.frame.size
        if button.width < 8 { button = NSSize(width: 88, height: 24) }
        saveButton.frame = NSRect(
            x: bounds.width - button.width,
            y: (barHeight - button.height) / 2,
            width: button.width,
            height: button.height
        )
        let fieldX = nameLabel.frame.maxX + 8
        let fieldWidth = max(40, saveButton.frame.minX - 8 - fieldX)
        nameField.frame = NSRect(x: fieldX, y: (barHeight - 24) / 2, width: fieldWidth, height: 24)
    }

    /// Пишет файл под именем из поля. Пустое имя не сохраняет.
    @objc private func saveClicked() {
        let name = NoteFile.cleanName(nameField.stringValue)
        guard !name.isEmpty else {
            NSSound.beep()
            window?.makeFirstResponder(nameField)
            return
        }
        let url: URL
        do {
            url = try NoteFile.write(text: textView.string, name: name)
        } catch {
            NSSound.beep()
            return
        }
        textView.string = ""
        textView.undoManager?.removeAllActions()
        nameField.stringValue = ""
        onFile?(url, saveButton)
    }
}
