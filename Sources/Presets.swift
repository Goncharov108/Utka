import AppKit

struct Preset: Codable, Equatable {
    var id: String
    var kind: String
    var title: String
    var body: String?
    var bookmark: String?
    var path: String?
    /// Будильник у заметки: когда напомнить. Только у текстовых записей.
    var dueAt: Date?
    /// true — будильник уже открывали, крякать заново не нужно, пока дата не сменится.
    var alarmAcknowledged: Bool?
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

    func addText(title: String, body: String, dueAt: Date? = nil) {
        items.insert(Preset(id: UUID().uuidString, kind: "text", title: title, body: body, bookmark: nil, path: nil, dueAt: dueAt, alarmAcknowledged: nil), at: 0)
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Preset].self, from: data)
            lastSaved = data
            loadError = ""
            onChange?()
        } catch {
            loadError = "presets.json не читается"
            onChange?()
        }
    }

    /// Будильник у заметки. nil — снять. Смена даты сбрасывает «уже открывали».
    func setAlarm(id: String, date: Date?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].dueAt = date
        items[index].alarmAcknowledged = nil
        save()
        onChange?()
    }

    /// Крик утки прекращается, заметка открыта — больше не кричит, пока дату не сменят.
    func acknowledgeAlarm(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].alarmAcknowledged != true else { return }
        items[index].alarmAcknowledged = true
        save()
        onChange?()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
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
    /// Сработавшую заметку открыли — пора остановить кряканье.
    var onAlarmOpened: ((String) -> Void)?
    /// id заметки, у которой сейчас кричит будильник. Красит её строку.
    var ringingID: String? {
        didSet { guard ringingID != oldValue else { return }; rebuild() }
    }

    private let model: PresetsModel
    private let tabControl = NSSegmentedControl()
    private let fileGrid = FileGridView(cardSize: NSSize(width: 100, height: 90))
    private let textScroll = NSScrollView()
    private let textDocument = FlippedView()
    private let emptyLabel = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let errorLabel = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let titleField = NSTextField()
    private let bodyField = NSTextField()
    private let addButton = NSButton()
    private let alarmButton = NSButton()
    private let alarmPopover = AlarmPopover()
    private var pendingAlarmDate: Date?
    private var rows: [TextRowView] = []
    private var expanded: Set<String> = []
    private var tab: PresetsTab = .notes
    private var removePrompt: RemovePrompt?
    private let noteStrip = DragStrip()
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
        fileGrid.onHold = { [weak self] on in self?.onDrag?(on) }
        fileGrid.onPlace = { [weak self] id, index in self?.model.place(id: id, at: index) }
        fileGrid.onSettled = { [weak self] in self?.rebuildIfPending() }
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
        styleAlarmButton()
        addSubview(tabControl)
        addSubview(fileGrid)
        addSubview(textScroll)
        addSubview(emptyLabel)
        addSubview(errorLabel)
        addSubview(titleField)
        addSubview(bodyField)
        addSubview(alarmButton)
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
        updateAlarmButton()
    }

    /// Кнопка-будильник для новой заметки: пусто, пока дата не выбрана.
    private func styleAlarmButton() {
        alarmButton.title = ""
        alarmButton.imagePosition = .imageOnly
        alarmButton.bezelStyle = .circular
        alarmButton.target = self
        alarmButton.action = #selector(alarmTapped)
        updateAlarmButton()
    }

    private func updateAlarmButton() {
        let symbol = pendingAlarmDate == nil ? "calendar" : "calendar.badge.clock"
        alarmButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Будильник")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        alarmButton.contentTintColor = pendingAlarmDate == nil ? UtkaChrome.dim : UtkaChrome.ink
        alarmButton.toolTip = pendingAlarmDate.map { "Напомнить \(alarmLabel($0))" } ?? "Поставить будильник к заметке"
    }

    @objc private func alarmTapped() {
        alarmPopover.onPresenting = { [weak self] active in self?.onDrag?(active) }
        alarmPopover.show(from: alarmButton, initial: pendingAlarmDate) { [weak self] date in
            self?.pendingAlarmDate = date
            self?.updateAlarmButton()
        }
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        model.reloadIfExternal()
    }

    /// Переключает на вкладку «Заметки» и раскрывает именно эту запись — так будильник
    /// находит свою заметку, когда по нему кликнули из строки меню.
    func openNote(id: String) {
        tab = .notes
        tabControl.selectedSegment = tab.rawValue
        expanded = [id]
        rebuild()
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
        fileGrid.isHidden = !showFiles
        textScroll.isHidden = !(showNotes || focus)
        titleField.isHidden = !showNotes
        bodyField.isHidden = !showNotes
        addButton.isHidden = !showNotes
        errorLabel.isHidden = !showNotes

        if focus {
            textScroll.frame = bounds
        } else if tab == .files {
            fileGrid.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(24, top))
        } else {
            let formY: CGFloat = 4
            let formH: CGFloat = 26
            let plus: CGFloat = 26
            let titleW = min(140, max(72, (bounds.width - plus * 2 - 24) * 0.34))
            titleField.frame = NSRect(x: 0, y: formY, width: titleW, height: formH)
            bodyField.frame = NSRect(x: titleW + 8, y: formY, width: max(40, bounds.width - titleW - plus * 2 - 24), height: formH)
            alarmButton.frame = NSRect(x: bounds.width - plus * 2 - 8, y: formY, width: plus, height: formH)
            addButton.frame = NSRect(x: bounds.width - plus, y: formY, width: plus, height: formH)
            errorLabel.frame = NSRect(x: 0, y: formY + formH + 2, width: bounds.width - plus - 8, height: 14)
            let textY = formY + formH + 18
            textScroll.frame = NSRect(x: 0, y: textY, width: bounds.width, height: max(24, top - textY))
        }

        let emptyIsForFiles = tab == .files
        emptyLabel.stringValue = emptyIsForFiles ? "Пусто. Перетащи сюда файл" : "Пусто. Допиши фразу ниже"
        emptyLabel.isHidden = focus || (emptyIsForFiles ? !fileGrid.isEmpty : !rows.isEmpty)
        emptyLabel.frame = emptyIsForFiles ? fileGrid.frame : (showNotes ? textScroll.frame : bounds)

        rows.forEach { $0.isHidden = tab != .notes || (focus && !$0.isExpanded) }
        let notesMove = rows.count > 1 && !focus
        rows.forEach { $0.canReorder = notesMove && !$0.isExpanded }

        layoutNotes()
        if focus {
            textScroll.contentView.scroll(to: .zero)
            textScroll.reflectScrolledClipView(textScroll.contentView)
        }
    }

    /// Пока строку тащат, список не выбрасывает: иначе жест обрывается.
    private func modelChanged() {
        rebuild()
    }

    /// Пересборка, которую отложили на время перетаскивания.
    private func rebuildIfPending() {
        guard rebuildPending else { return }
        rebuildPending = false
        rebuild()
    }

    private func rebuild() {
        guard noteStrip.drag == nil, !fileGrid.isDragging else {
            rebuildPending = true
            return
        }
        noteStrip.reset()
        textDocument.subviews.forEach { $0.removeFromSuperview() }
        fileGrid.setCards(model.files.map { preset in
            let card = FileCardView()
            card.show(url: model.url(for: preset), title: preset.title)
            card.consumeOnDrop = false
            card.onDrag = { [weak self] active in self?.onDrag?(active) }
            card.onRemove = { [weak self] in self?.askRemove(preset) }
            if let url = model.url(for: preset) {
                card.onEdit = { ShotEditor.open(url: url) }
            }
            return (preset.id, card)
        })
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
            row.show(
                title: preset.title,
                detail: oneLine(preset.body ?? ""),
                body: preset.body ?? "",
                dueAt: preset.dueAt,
                ringing: preset.id == self.ringingID
            )
            row.onAlarmPicked = { [weak self] date in self?.model.setAlarm(id: preset.id, date: date) }
            row.onClick = { [weak self] in
                guard let self else { return }
                if preset.id == self.ringingID { self.onAlarmOpened?(preset.id) }
                guard let body = preset.body else { return }
                self.copyText(body)
            }
            row.onCopySelection = { [weak self] piece in self?.copyText(piece) }
            row.onSelecting = { [weak self] active in self?.onDrag?(active) }
            row.onToggle = { [weak self, weak row] in
                guard let self, let row else { return }
                let open = !self.expanded.contains(preset.id)
                self.expanded = open ? [preset.id] : []
                self.rows.forEach { $0.isExpanded = false }
                row.isExpanded = open
                if open, preset.id == self.ringingID { self.onAlarmOpened?(preset.id) }
                self.applyLayout()
            }
            row.onDelete = { [weak self] in self?.askRemove(preset) }
            textDocument.addSubview(row)
            return row
        }
        errorLabel.stringValue = model.loadError
        applyLayout()
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

    /// Меняет видимый порядок заметок и пишет его в модель, не пересобирая строки.
    private func shift(rows: inout [TextRowView], view: TextRowView, to target: Int, id: String) {
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
        let moving = noteStrip.step()
        applyLayout()
        guard !moving else { return }
        noteStrip.finish()
        timer.invalidate()
        motionTimer = nil
        applyLayout()
        rebuildIfPending()
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
        model.addText(title: title.isEmpty ? oneLine(body, limit: 32) : title, body: body, dueAt: pendingAlarmDate)
        titleField.stringValue = ""
        bodyField.stringValue = ""
        pendingAlarmDate = nil
        updateAlarmButton()
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
