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
        let name = (preset.path as NSString?)?.lastPathComponent ?? preset.title
        return BookmarkStore.locate(bookmark: preset.bookmark, path: preset.path, name: name)
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

private enum PresetsTab: Int {
    case notes, files
}

/// Заготовки: переключатель наверху разводит фразы и файлы по разным вкладкам,
/// чтобы список заметок не делил место с полосой файлов.
final class PresetsView: NSView {
    var onDrag: ((Bool) -> Void)?
    var copyText: (String) -> Void = { _ in }

    private let model: PresetsModel
    private let tabControl = NSSegmentedControl()
    private let fileScroll = NSScrollView()
    private let fileDocument = FlippedView()
    private let textScroll = NSScrollView()
    private let textDocument = FlippedView()
    private let emptyLabel = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let errorLabel = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let titleField = NSTextField()
    private let bodyField = NSTextField()
    private let addButton = NSButton()
    private var cards: [FileCardView] = []
    private var rows: [TextRowView] = []
    private var expanded: Set<String> = []
    private var tab: PresetsTab = .notes

    init(model: PresetsModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        tabControl.segmentStyle = .texturedRounded
        tabControl.segmentCount = 2
        tabControl.setLabel("Заметки", forSegment: PresetsTab.notes.rawValue)
        tabControl.setLabel("Файлы", forSegment: PresetsTab.files.rawValue)
        tabControl.selectedSegment = tab.rawValue
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        let fileClip = FlippedClipView()
        fileScroll.contentView = fileClip
        fileScroll.documentView = fileDocument
        fileScroll.hasVerticalScroller = true
        fileScroll.drawsBackground = false
        fileScroll.autohidesScrollers = true
        let textClip = FlippedClipView()
        textScroll.contentView = textClip
        textScroll.documentView = textDocument
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.autohidesScrollers = true
        emptyLabel.alignment = .center
        styleField(titleField, placeholder: "Название")
        styleField(bodyField, placeholder: "Фраза, адрес или ссылка")
        addButton.title = ""
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        addButton.imagePosition = .imageOnly
        addButton.bezelStyle = .circular
        addButton.contentTintColor = .white
        addButton.target = self
        addButton.action = #selector(addText)
        addSubview(tabControl)
        addSubview(fileScroll)
        addSubview(textScroll)
        addSubview(emptyLabel)
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
        applyLayout()
    }

    private var focused: Bool { rows.contains { $0.isExpanded } }

    /// Раскладка целиком зависит от вкладки и от того, раскрыта ли заметка.
    private func applyLayout() {
        let focus = focused
        tabControl.isHidden = focus
        let tabH: CGFloat = 24
        let top = focus ? bounds.height : bounds.height - tabH - 6
        tabControl.frame = NSRect(x: 0, y: bounds.height - tabH, width: 160, height: tabH)

        let showFiles = tab == .files && !focus
        let showNotes = tab == .notes && !focus
        fileScroll.isHidden = !showFiles
        textScroll.isHidden = !(showNotes || focus)
        titleField.isHidden = !showNotes
        bodyField.isHidden = !showNotes
        addButton.isHidden = !showNotes
        errorLabel.isHidden = !showNotes

        if focus {
            textScroll.frame = bounds
        } else if tab == .files {
            fileScroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(24, top))
        } else {
            let formY: CGFloat = 4
            let formH: CGFloat = 26
            let plus: CGFloat = 26
            let titleW = min(140, max(72, (bounds.width - plus - 16) * 0.34))
            titleField.frame = NSRect(x: 0, y: formY, width: titleW, height: formH)
            bodyField.frame = NSRect(x: titleW + 8, y: formY, width: max(40, bounds.width - titleW - plus - 16), height: formH)
            addButton.frame = NSRect(x: bounds.width - plus, y: formY, width: plus, height: formH)
            errorLabel.frame = NSRect(x: 0, y: formY + formH + 2, width: bounds.width - plus - 8, height: 14)
            let textY = formY + formH + 18
            textScroll.frame = NSRect(x: 0, y: textY, width: bounds.width, height: max(24, top - textY))
        }

        let emptyIsForFiles = tab == .files
        emptyLabel.stringValue = emptyIsForFiles ? "Пусто. Перетащи сюда файл" : "Пусто. Допиши фразу ниже"
        emptyLabel.isHidden = focus || (emptyIsForFiles ? !cards.isEmpty : !rows.isEmpty)
        emptyLabel.frame = emptyIsForFiles ? fileScroll.frame : (showNotes ? textScroll.frame : bounds)

        rows.forEach { $0.isHidden = tab != .notes || (focus && !$0.isExpanded) }
        cards.forEach { $0.isHidden = tab != .files }

        layoutContent()
        if focus {
            textScroll.contentView.scroll(to: .zero)
            textScroll.reflectScrolledClipView(textScroll.contentView)
        }
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
            if let url = model.url(for: preset) {
                card.onEdit = { ShotEditor.open(url: url) }
            }
            fileDocument.addSubview(card)
            return card
        }
        rows = model.texts.map { preset in
            let row = TextRowView()
            row.isExpanded = expanded.contains(preset.id)
            row.show(title: preset.title, detail: oneLine(preset.body ?? ""), body: preset.body ?? "")
            row.onClick = { [weak self] in
                guard let body = preset.body else { return }
                self?.copyText(body)
            }
            row.onCopySelection = { [weak self] piece in self?.copyText(piece) }
            row.onSelecting = { [weak self] active in self?.onDrag?(active) }
            row.onToggle = { [weak self, weak row] in
                guard let self, let row else { return }
                let open = !self.expanded.contains(preset.id)
                self.expanded = open ? [preset.id] : []
                self.rows.forEach { $0.isExpanded = false }
                row.isExpanded = open
                self.applyLayout()
            }
            row.onDelete = { [weak self] in self?.model.remove(id: preset.id) }
            textDocument.addSubview(row)
            return row
        }
        errorLabel.stringValue = model.loadError
        applyLayout()
    }

    /// Карточки файлов переносятся по строкам сеткой, а не одной горизонтальной лентой.
    private func layoutContent() {
        let cardW: CGFloat = 100
        let cardH: CGFloat = 90
        let gap: CGFloat = 12
        let width = max(fileScroll.contentView.bounds.width, fileScroll.bounds.width)
        let perRow = max(1, Int((width + gap) / (cardW + gap)))
        var x: CGFloat = 0
        var y: CGFloat = 0
        var col = 0
        for card in cards {
            card.frame = NSRect(x: x, y: y, width: cardW, height: cardH)
            col += 1
            if col >= perRow {
                col = 0
                x = 0
                y += cardH + gap
            } else {
                x += cardW + gap
            }
        }
        let rowsUsed = cards.isEmpty ? 0 : (col == 0 ? y : y + cardH + gap)
        fileDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(rowsUsed, fileScroll.contentView.bounds.height))

        let textWidth = max(textScroll.contentView.bounds.width, textScroll.bounds.width)
        var ty: CGFloat = 0
        for row in rows {
            let height = row.isExpanded ? max(TextRowView.expandedHeight, textScroll.bounds.height) : TextRowView.collapsedHeight
            row.frame = NSRect(x: 0, y: ty, width: textWidth, height: height)
            ty += height + 6
        }
        textDocument.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(ty, textScroll.contentView.bounds.height))
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

    @objc private func tabChanged() {
        guard let value = PresetsTab(rawValue: tabControl.selectedSegment) else { return }
        tab = value
        applyLayout()
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
        tab = .files
        tabControl.selectedSegment = tab.rawValue
        applyLayout()
        return true
    }
}
