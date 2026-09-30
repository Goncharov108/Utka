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

    /// Ставит запись на место среди своего вида. Соседей другого вида не двигает и список не пересобирает.
    func place(id: String, at visibleIndex: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let kind = items[index].kind
        let slots = items.indices.filter { items[$0].kind == kind }
        guard let from = slots.firstIndex(of: index) else { return }
        let target = min(max(0, visibleIndex), slots.count - 1)
        guard from != target else { return }
        var group = slots.map { items[$0] }
        let moved = group.remove(at: from)
        group.insert(moved, at: target)
        for (slot, item) in zip(slots, group) {
            items[slot] = item
        }
        save()
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

/// Плавная перестановка: тащимая карточка едет за курсором, остальные догоняют слоты.
private final class DragStrip {
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
    private var removePrompt: RemovePrompt?
    private let noteStrip = DragStrip()
    private let fileStrip = DragStrip()
    private var motionTimer: Timer?
    private var islandHeld = false
    private var rebuildPending = false
    private let notePitch = TextRowView.collapsedHeight + 6

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
        addButton.contentTintColor = UtkaChrome.ink
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
        model.onChange = { [weak self] in self?.modelChanged() }
        NotificationCenter.default.addObserver(self, selector: #selector(retintPresets), name: IslandLook.changed, object: nil)
        rebuild()
    }

    /// Поля и подписи заготовок под текущий вид.
    @objc private func retintPresets() {
        styleField(titleField, placeholder: "Название")
        styleField(bodyField, placeholder: "Фраза, адрес или ссылка")
        addButton.contentTintColor = UtkaChrome.ink
        emptyLabel.textColor = UtkaChrome.dim
        errorLabel.textColor = UtkaChrome.dim
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
        let notesMove = rows.count > 1 && !focus
        rows.forEach { $0.canReorder = notesMove && !$0.isExpanded }
        cards.forEach { $0.canReorder = cards.count > 1 }

        layoutContent()
        if focus {
            textScroll.contentView.scroll(to: .zero)
            textScroll.reflectScrolledClipView(textScroll.contentView)
        }
    }

    /// Пока строку тащат, список не выбрасывает: иначе жест обрывается.
    private func modelChanged() {
        guard noteStrip.drag == nil, fileStrip.drag == nil else {
            rebuildPending = true
            return
        }
        rebuild()
    }

    private func rebuild() {
        guard noteStrip.drag == nil, fileStrip.drag == nil else {
            rebuildPending = true
            return
        }
        noteStrip.reset()
        fileStrip.reset()
        fileDocument.subviews.forEach { $0.removeFromSuperview() }
        textDocument.subviews.forEach { $0.removeFromSuperview() }
        let files = model.files
        cards = files.map { preset in
            let card = FileCardView()
            card.show(url: model.url(for: preset), title: preset.title)
            card.consumeOnDrop = false
            card.onDrag = { [weak self] active in self?.onDrag?(active) }
            card.onRemove = { [weak self] in self?.askRemove(preset) }
            card.canReorder = files.count > 1
            card.onReorderDrag = { [weak self, weak card] origin in
                guard let self, let card else { return }
                self.dragFile(card, id: preset.id, to: origin)
            }
            card.onReorderDrop = { [weak self] in self?.dropFile() }
            if let url = model.url(for: preset) {
                card.onEdit = { ShotEditor.open(url: url) }
            }
            fileDocument.addSubview(card)
            return card
        }
        let texts = model.texts
        rows = texts.map { preset in
            let row = TextRowView()
            row.isExpanded = expanded.contains(preset.id)
            row.canReorder = texts.count > 1
            row.onReorderDrag = { [weak self, weak row] y in
                guard let self, let row else { return }
                self.dragNote(row, id: preset.id, to: y)
            }
            row.onReorderDrop = { [weak self] in self?.dropNote() }
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
            row.onDelete = { [weak self] in self?.askRemove(preset) }
            textDocument.addSubview(row)
            return row
        }
        errorLabel.stringValue = model.loadError
        applyLayout()
    }

    /// Карточки файлов переносятся по строкам сеткой, а не одной горизонтальной лентой.
    private func layoutContent() {
        layoutFiles()
        layoutNotes()
    }

    /// Сетка файлов. Пока карточку тащат за полоски, она едет за курсором.
    private func layoutFiles() {
        let grid = fileGrid()
        for (index, card) in cards.enumerated() {
            let home = fileSlot(index, grid)
            fileStrip.place(card, home: home, size: NSSize(width: grid.cardW, height: grid.cardH))
        }
        let rowsHigh = cards.isEmpty ? 0 : Int(ceil(Double(cards.count) / Double(grid.per)))
        let height = CGFloat(rowsHigh) * (grid.cardH + grid.gap)
        fileDocument.frame = NSRect(x: 0, y: 0, width: grid.width, height: max(height, fileScroll.contentView.bounds.height))
        if let top = fileStrip.drag ?? fileStrip.settling {
            fileDocument.addSubview(top, positioned: .above, relativeTo: nil)
        }
    }

    /// Заметки столбиком. Раскрытая строка выше остальных, её в этот момент не тащат.
    private func layoutNotes() {
        let width = max(textScroll.contentView.bounds.width, textScroll.bounds.width)
        if rows.contains(where: { $0.isExpanded }) {
            var ty: CGFloat = 0
            for row in rows {
                let height = row.isExpanded ? max(TextRowView.expandedHeight, textScroll.bounds.height) : TextRowView.collapsedHeight
                row.setLift(0)
                row.frame = NSRect(x: 0, y: ty, width: width, height: height)
                ty += height + 6
            }
            textDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(ty, textScroll.contentView.bounds.height))
            return
        }
        for (index, row) in rows.enumerated() {
            let home = NSPoint(x: 0, y: CGFloat(index) * notePitch)
            noteStrip.place(row, home: home, size: NSSize(width: width, height: TextRowView.collapsedHeight))
        }
        let height = CGFloat(rows.count) * notePitch
        textDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(height, textScroll.contentView.bounds.height))
        if let top = noteStrip.drag ?? noteStrip.settling {
            textDocument.addSubview(top, positioned: .above, relativeTo: nil)
        }
    }

    /// Тащит заметку и меняет её местами с той, чью середину пересекла.
    private func dragNote(_ row: TextRowView, id: String, to y: CGFloat) {
        if noteStrip.drag == nil {
            noteStrip.begin(row)
            holdIsland(true)
        }
        let limit = CGFloat(max(0, rows.count - 1)) * notePitch
        noteStrip.dragOrigin = NSPoint(x: 0, y: min(max(0, y), limit))
        let target = min(max(0, Int((noteStrip.dragOrigin.y / notePitch).rounded())), max(0, rows.count - 1))
        shift(rows: &rows, view: row, to: target, id: id)
        kickMotion()
        applyLayout()
        row.scrollToVisible(row.bounds)
    }

    private func dropNote() {
        noteStrip.end()
        holdIsland(false)
        kickMotion()
        applyLayout()
    }

    /// Тащит файл по сетке. Превью по-прежнему уносит файл наружу.
    private func dragFile(_ card: FileCardView, id: String, to origin: NSPoint) {
        if fileStrip.drag == nil {
            fileStrip.begin(card)
            holdIsland(true)
        }
        let grid = fileGrid()
        fileStrip.dragOrigin = clampFile(origin, count: cards.count, grid: grid)
        let target = fileIndex(at: fileStrip.dragOrigin, count: cards.count, grid: grid)
        shift(rows: &cards, view: card, to: target, id: id)
        kickMotion()
        applyLayout()
        card.scrollToVisible(card.bounds)
    }

    private func dropFile() {
        fileStrip.end()
        holdIsland(false)
        kickMotion()
        applyLayout()
    }

    /// Меняет видимый порядок и пишет его в модель, не пересобирая строки.
    private func shift<T: NSView>(rows: inout [T], view: T, to target: Int, id: String) {
        guard let from = rows.firstIndex(where: { $0 === view }), from != target else { return }
        rows.remove(at: from)
        rows.insert(view, at: target)
        model.place(id: id, at: target)
    }

    /// Держит островок открытым, пока карточку тащат внутри списка.
    private func holdIsland(_ on: Bool) {
        guard islandHeld != on else { return }
        islandHeld = on
        onDrag?(on)
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
        let moving = noteStrip.step() || fileStrip.step()
        applyLayout()
        guard moving else {
            noteStrip.finish()
            fileStrip.finish()
            timer.invalidate()
            motionTimer = nil
            applyLayout()
            guard rebuildPending else { return }
            rebuildPending = false
            rebuild()
            return
        }
    }

    private struct FileGrid {
        var width: CGFloat
        var per: Int
        var cardW: CGFloat
        var cardH: CGFloat
        var gap: CGFloat
    }

    /// Ширина прокрутки и сколько карточек встаёт в ряд.
    private func fileGrid() -> FileGrid {
        let cardW: CGFloat = 100
        let cardH: CGFloat = 90
        let gap: CGFloat = 12
        let width = max(fileScroll.contentView.bounds.width, fileScroll.bounds.width, 1)
        let per = max(1, Int((width + gap) / (cardW + gap)))
        return FileGrid(width: width, per: per, cardW: cardW, cardH: cardH, gap: gap)
    }

    /// Левый верх слота в документе, ноль сверху.
    private func fileSlot(_ index: Int, _ grid: FileGrid) -> NSPoint {
        let col = index % grid.per
        let row = index / grid.per
        return NSPoint(x: CGFloat(col) * (grid.cardW + grid.gap), y: CGFloat(row) * (grid.cardH + grid.gap))
    }

    /// Не даёт карточке уехать за край сетки.
    private func clampFile(_ origin: NSPoint, count: Int, grid: FileGrid) -> NSPoint {
        let columns = CGFloat(max(0, grid.per - 1))
        let rowsHigh = Int(ceil(Double(max(count, 1)) / Double(grid.per)))
        let rows = CGFloat(max(0, rowsHigh - 1))
        let stepX = grid.cardW + grid.gap
        let stepY = grid.cardH + grid.gap
        return NSPoint(
            x: min(max(0, origin.x), columns * stepX),
            y: min(max(0, origin.y), rows * stepY)
        )
    }

    /// Слот, в который попал центр тащимой карточки.
    private func fileIndex(at origin: NSPoint, count: Int, grid: FileGrid) -> Int {
        guard count > 0 else { return 0 }
        let stepX = grid.cardW + grid.gap
        let stepY = grid.cardH + grid.gap
        let col = min(max(0, Int((origin.x / stepX).rounded())), grid.per - 1)
        let row = max(0, Int((origin.y / stepY).rounded()))
        return min(row * grid.per + col, count - 1)
    }

    private func styleField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = UtkaChrome.font(12)
        field.textColor = UtkaChrome.ink
        field.backgroundColor = UtkaChrome.card
        field.isBordered = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
    }

    @objc private func tabChanged() {
        guard let value = PresetsTab(rawValue: tabControl.selectedSegment) else { return }
        tab = value
        applyLayout()
    }

    /// Спрашивает и только потом снимает запись. Файл на диске не стирает.
    private func askRemove(_ preset: Preset) {
        guard removePrompt == nil else { return }
        let text = preset.kind == "file"
            ? "Убрать запись из утки? Файл на диске останется."
            : "Убрать заметку из списка?"
        onDrag?(true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let prompt = RemovePrompt(text: text)
            self.removePrompt = prompt
            prompt.onChoose = { [weak self] drop in
                self?.removePrompt = nil
                self?.onDrag?(false)
                guard drop else { return }
                self?.model.remove(id: preset.id)
            }
            prompt.show(over: self.window)
        }
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

/// Короткое окно поверх островка: убрать запись или оставить.
private final class RemovePrompt: NSObject {
    var onChoose: ((Bool) -> Void)?

    private let window: RemoveWindow
    private let card = UtkaPanelChrome()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let dropButton = NSButton()
    private let keepButton = NSButton()
    private var escapeMonitor: Any?
    private var lookToken: NSObjectProtocol?
    private var closed = false

    init(text: String) {
        window = RemoveWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.cancel = { [weak self] in self?.finish(drop: false) }

        window.contentView = card

        message.stringValue = text
        message.font = UtkaChrome.font(13)
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.drawsBackground = false
        message.isBezeled = false
        message.isEditable = false
        message.isSelectable = false
        card.addSubview(message)

        style(dropButton, title: "Убрать", action: #selector(dropTapped))
        style(keepButton, title: "Оставить", action: #selector(keepTapped))
        card.addSubview(dropButton)
        card.addSubview(keepButton)
        lookToken = UtkaChrome.track(window) { [weak self] in
            self?.applyLook()
        }
    }

    /// Текст и кнопки под текущий вид. Фон карточки обновляет само стекло.
    private func applyLook() {
        card.apply()
        message.textColor = UtkaChrome.ink
        dropButton.appearance = window.appearance
        keepButton.appearance = window.appearance
    }

    /// Ставит карточку по центру островка, не включая модальный режим приложения.
    func show(over host: NSWindow?) {
        let cardW: CGFloat = 360
        let cardH: CGFloat = 140
        let area = host?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: cardW, height: cardH)
        window.setFrame(NSRect(
            x: area.midX - cardW / 2,
            y: area.midY - cardH / 2,
            width: cardW,
            height: cardH
        ), display: false)
        layoutCard()
        window.orderFrontRegardless()
        window.makeKey()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(drop: false)
            return nil
        }
    }

    private func style(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = UtkaChrome.font(13, weight: .medium)
        button.target = self
        button.action = action
    }

    private func layoutCard() {
        let cardW: CGFloat = 360
        let pad: CGFloat = 16
        message.frame = NSRect(x: pad, y: 58, width: cardW - pad * 2, height: 64)
        let buttonW: CGFloat = 104
        let buttonH: CGFloat = 28
        keepButton.frame = NSRect(x: cardW - pad - buttonW, y: 16, width: buttonW, height: buttonH)
        dropButton.frame = NSRect(x: keepButton.frame.minX - 8 - buttonW, y: 16, width: buttonW, height: buttonH)
    }

    @objc private func dropTapped() { finish(drop: true) }
    @objc private func keepTapped() { finish(drop: false) }

    /// drop — снять запись. Иначе оставить как было.
    private func finish(drop: Bool) {
        guard !closed else { return }
        closed = true
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let lookToken {
            NotificationCenter.default.removeObserver(lookToken)
            self.lookToken = nil
        }
        window.orderOut(nil)
        onChoose?(drop)
    }
}

/// Безрамочное окно вопроса. Escape ничего не удаляет.
private final class RemoveWindow: NSWindow {
    var cancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        cancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel?()
            return
        }
        super.keyDown(with: event)
    }
}
