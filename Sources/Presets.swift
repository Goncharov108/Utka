import AppKit

struct Preset: Codable, Equatable {
    var id: String
    var kind: String
    var title: String
    var body: String?
    var bookmark: String?
    var path: String?
}

/// Постоянные фразы и файлы. Удаление снимает только запись.
final class PresetsModel {
    private(set) var items: [Preset] = []
    var loadError = ""
    var onChange: (() -> Void)?

    private let storeURL: URL
    private var lastSaved: Data?
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var watchTimer: Timer?

    init(storeURL: URL) {
        self.storeURL = storeURL
        if !FileManager.default.fileExists(atPath: storeURL.path) {
            try? Data("[]\n".utf8).write(to: storeURL)
        }
        reloadIfExternal()
        watchDirectory()
    }

    var texts: [Preset] { items.filter { $0.kind == "text" } }
    var files: [Preset] { items.filter { $0.kind == "file" } }

    func addText(title: String, body: String) {
        items.insert(Preset(id: UUID().uuidString, kind: "text", title: title, body: body, bookmark: nil, path: nil), at: 0)
        save()
        onChange?()
    }

    func addFiles(_ urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if items.contains(where: { $0.path == path }) { continue }
            guard let data = BookmarkStore.data(for: url) else { continue }
            items.insert(Preset(
                id: UUID().uuidString,
                kind: "file",
                title: url.lastPathComponent,
                body: nil,
                bookmark: data.base64EncodedString(),
                path: path
            ), at: 0)
            changed = true
        }
        guard changed else { return }
        save()
        onChange?()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func url(for preset: Preset) -> URL? {
        if let raw = preset.bookmark, let data = Data(base64Encoded: raw),
           let url = BookmarkStore.url(from: data),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let path = preset.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func reloadIfExternal() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if data == lastSaved { return }
        do {
            items = try JSONDecoder().decode([Preset].self, from: data)
            lastSaved = data
            loadError = ""
            onChange?()
        } catch {
            loadError = "presets.json не читается"
            onChange?()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        lastSaved = data
        try? data.write(to: storeURL, options: .atomic)
    }

    private func watchDirectory() {
        let dir = storeURL.deletingLastPathComponent()
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.watchTimer?.invalidate()
            self?.watchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                self?.reloadIfExternal()
            }
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { Darwin.close(fd) }
        }
        source.resume()
        watchSource = source
    }
}

/// Заготовки: файлы сверху, фразы списком, внизу добавление текста.
final class PresetsView: NSView {
    var onDrag: ((Bool) -> Void)?
    var copyText: (String) -> Void = { _ in }

    private let model: PresetsModel
    private let fileScroll = NSScrollView()
    private let fileDocument = NSView()
    private let textScroll = NSScrollView()
    private let textDocument = FlippedView()
    private let emptyFiles = UtkaChrome.label("Перетащи файл", size: 12, color: UtkaChrome.dim)
    private let errorLabel = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let titleField = NSTextField()
    private let bodyField = NSTextField()
    private let addButton = NSButton()
    private var cards: [FileCardView] = []
    private var rows: [TextRowView] = []

    init(model: PresetsModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        fileScroll.documentView = fileDocument
        fileScroll.hasHorizontalScroller = true
        fileScroll.drawsBackground = false
        fileScroll.autohidesScrollers = true
        let clip = FlippedClipView()
        textScroll.contentView = clip
        textScroll.documentView = textDocument
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.autohidesScrollers = true
        emptyFiles.alignment = .center
        styleField(titleField, placeholder: "Название")
        styleField(bodyField, placeholder: "Фраза, адрес или ссылка")
        addButton.title = "Добавить"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addText)
        addSubview(fileScroll)
        addSubview(emptyFiles)
        addSubview(textScroll)
        addSubview(errorLabel)
        addSubview(titleField)
        addSubview(bodyField)
        addSubview(addButton)
        registerForDraggedTypes([.fileURL])
        model.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        model.reloadIfExternal()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        let fileH: CGFloat = 118
        fileScroll.frame = NSRect(x: 0, y: bounds.height - fileH, width: bounds.width, height: fileH)
        emptyFiles.frame = fileScroll.frame
        let formY: CGFloat = 0
        let formH: CGFloat = 28
        titleField.frame = NSRect(x: 0, y: formY, width: 120, height: formH)
        bodyField.frame = NSRect(x: 128, y: formY, width: max(80, bounds.width - 230), height: formH)
        addButton.frame = NSRect(x: bounds.width - 96, y: formY - 2, width: 96, height: formH)
        errorLabel.frame = NSRect(x: 0, y: formH + 4, width: bounds.width, height: 16)
        textScroll.frame = NSRect(x: 0, y: formH + 22, width: bounds.width, height: max(40, bounds.height - fileH - formH - 28))
        layoutContent()
    }

    private func rebuild() {
        fileDocument.subviews.forEach { $0.removeFromSuperview() }
        textDocument.subviews.forEach { $0.removeFromSuperview() }
        cards = model.files.map { preset in
            let card = FileCardView()
            card.show(url: model.url(for: preset), title: preset.title)
            card.consumeOnDrop = false
            card.onDrag = { [weak self] active in self?.onDrag?(active) }
            card.onRemove = { [weak self] in self?.model.remove(id: preset.id) }
            fileDocument.addSubview(card)
            return card
        }
        rows = model.texts.map { preset in
            let row = TextRowView()
            row.show(title: preset.title, detail: oneLine(preset.body ?? ""))
            row.onClick = { [weak self] in
                guard let body = preset.body else { return }
                self?.copyText(body)
            }
            row.onDelete = { [weak self] in self?.model.remove(id: preset.id) }
            textDocument.addSubview(row)
            return row
        }
        emptyFiles.isHidden = !cards.isEmpty
        errorLabel.stringValue = model.loadError
        layoutContent()
    }

    private func layoutContent() {
        var x: CGFloat = 0
        for card in cards {
            card.frame = NSRect(x: x, y: 4, width: 112, height: 104)
            x += 120
        }
        fileDocument.frame = NSRect(x: 0, y: 0, width: max(x, 1), height: 112)
        let width = max(textScroll.contentView.bounds.width, textScroll.bounds.width)
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: 48)
            y += 54
        }
        textDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(y, textScroll.contentView.bounds.height))
    }

    private func styleField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = UtkaChrome.font(12)
        field.textColor = .white
        field.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        field.isBordered = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
    }

    @objc private func addText() {
        let body = bodyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.addText(title: title.isEmpty ? oneLine(body, limit: 32) : title, body: body)
        titleField.stringValue = ""
        bodyField.stringValue = ""
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        model.addFiles(urls)
        return true
    }
}
