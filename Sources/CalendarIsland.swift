import AppKit

/// Понедельник и русские подписи. Сетка и заметки считают дни одинаково.
enum CalendarClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    /// Начало местных суток.
    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Первый день месяца.
    static func monthStart(_ date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: parts) ?? startOfDay(date)
    }

    /// Один и тот же местный день.
    static func sameDay(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, inSameDayAs: b)
    }

    /// «Ноябрь 2026».
    static func monthTitle(_ date: Date) -> String {
        titled(date, format: "LLLL yyyy")
    }

    /// «11 ноября» или с годом, если день не в этом году.
    static func dayTitle(_ date: Date) -> String {
        let format = calendar.isDate(date, equalTo: Date(), toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        return titled(date, format: format)
    }

    /// «14:30».
    static func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// День и час:минуты в одну дату. Секунды всегда ноль.
    static func combining(day: Date, hour: Int, minute: Int) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: startOfDay(day))
    }

    /// Просрочено — раньше сегодня, остальное по суткам.
    static func bucket(_ date: Date, now: Date = Date()) -> CalendarBucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInTomorrow(date) { return .tomorrow }
        if date < startOfDay(now) { return .overdue }
        return .later
    }

    /// Пн … Вс, с заглавной.
    static let weekdays: [String] = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        let symbols = formatter.shortStandaloneWeekdaySymbols ?? ["вс", "пн", "вт", "ср", "чт", "пт", "сб"]
        let ordered = Array(symbols.dropFirst()) + [symbols[0]]
        return ordered.map { word in
            let lower = word.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
    }()

    /// Первая буква заглавная: форматтер отдаёт «ноябрь».
    private static func titled(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.dateFormat = format
        let raw = formatter.string(from: date)
        guard let first = raw.first else { return raw }
        return String(first).uppercased() + raw.dropFirst()
    }
}

/// Куда встать заметке в спокойной очереди.
enum CalendarBucket: CaseIterable {
    case overdue, today, tomorrow, later

    var title: String {
        switch self {
        case .overdue: return "Просрочено"
        case .today: return "Сегодня"
        case .tomorrow: return "Завтра"
        case .later: return "Позже"
        }
    }
}

/// Заметка календаря. Живёт в calendar.json, не в закрепах.
struct CalendarNote: Codable, Equatable {
    var id: String
    var title: String
    var body: String
    var at: Date
    var quack: Bool
    var acknowledged: Bool
}

/// Файл заметок календаря. Снятие раздела файл не удаляет.
final class CalendarModel {
    static let changed = Notification.Name("utka.calendarNotes")

    private(set) var notes: [CalendarNote] = []
    private(set) var loadError = ""
    private let storeURL: URL
    /// Битый файл не затираем пустым списком.
    private var canSave = true

    init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    /// Новая или правка. Смена времени или кряка снова разрешает звон.
    func upsert(_ note: CalendarNote) {
        guard canSave else { return }
        var note = note
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            let old = notes[index]
            if old.at != note.at || old.quack != note.quack {
                note.acknowledged = false
            }
            notes[index] = note
        } else {
            notes.append(note)
        }
        save()
    }

    /// Снимает заметку. Файл остаётся, даже если список пуст.
    func remove(id: String) {
        guard canSave else { return }
        let before = notes.count
        notes.removeAll { $0.id == id }
        guard notes.count != before else { return }
        save()
    }

    /// Заметку открыли — этот срок больше не крякает.
    func acknowledge(id: String) {
        guard canSave, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        guard !notes[index].acknowledged else { return }
        notes[index].acknowledged = true
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL), !data.isEmpty else {
            canSave = false
            loadError = "calendar.json не читается"
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([CalendarNote].self, from: data)
        } catch {
            canSave = false
            loadError = "calendar.json не читается"
        }
    }

    private func save() {
        guard canSave else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        do {
            try data.write(to: storeURL, options: .atomic)
        } catch {
            loadError = "calendar.json не записывается"
            return
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// Кнопка-значок без рамки.
private func calendarIconButton(symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton()
    button.title = ""
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.contentTintColor = UtkaChrome.ink
    button.toolTip = tip
    button.target = target
    button.action = action
    return button
}

/// Месяц слева: своя сетка, без системного календаря.
private final class MonthGrid: NSView {
    var onDay: ((Date) -> Void)?
    var onMonth: ((Int) -> Void)?

    private var month = CalendarClock.monthStart(Date())
    private var selected: Date?
    private var marked = Set<Date>()
    private let previous = calendarIconButton(symbol: "chevron.left", tip: "Предыдущий месяц", target: MonthGrid.holder, action: #selector(MonthGrid.shiftBack))
    private let next = calendarIconButton(symbol: "chevron.right", tip: "Следующий месяц", target: MonthGrid.holder, action: #selector(MonthGrid.shiftForward))
    /// Временный якорь, пока кнопка не знает self. Сразу меняется в init.
    private static let holder = NSObject()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previous.target = self
        previous.action = #selector(shiftBack)
        next.target = self
        next.action = #selector(shiftForward)
        addSubview(previous)
        addSubview(next)
    }

    required init?(coder: NSCoder) { nil }

    /// Месяц, выбранный день и дни, под которыми точка.
    func show(month: Date, selected: Date?, marked: Set<Date>) {
        self.month = CalendarClock.monthStart(month)
        self.selected = selected.map(CalendarClock.startOfDay)
        self.marked = marked
        needsLayout = true
        needsDisplay = true
    }

    /// Краски стрелок под тему. Дни читают цвет в момент отрисовки.
    func applyLook() {
        previous.contentTintColor = UtkaChrome.ink
        next.contentTintColor = UtkaChrome.ink
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let font = UtkaChrome.font(13, weight: .semibold)
        let titleW = ceil((CalendarClock.monthTitle(month) as NSString).size(withAttributes: [.font: font]).width)
        let cluster = 22 + 4 + titleW + 4 + 22
        let origin = max(0, (bounds.width - 30 - cluster) / 2)
        previous.frame = NSRect(x: origin, y: 3, width: 22, height: 22)
        next.frame = NSRect(x: origin + 26 + titleW, y: 3, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawTitle()
        drawWeekdays()
        for cell in dayCells() where cell.inMonth {
            draw(cell)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let day = dayCells().first(where: { $0.inMonth && $0.rect.contains(point) }) else { return }
        onDay?(CalendarClock.startOfDay(day.date))
    }

    @objc private func shiftBack() { onMonth?(-1) }
    @objc private func shiftForward() { onMonth?(1) }

    private func drawTitle() {
        let font = UtkaChrome.font(13, weight: .semibold)
        let title = CalendarClock.monthTitle(month) as NSString
        let width = ceil(title.size(withAttributes: [.font: font]).width)
        let rect = NSRect(x: previous.frame.maxX + 4, y: 4, width: width, height: 20)
        title.draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: UtkaChrome.ink
        ])
    }

    private func drawWeekdays() {
        let font = UtkaChrome.font(10, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UtkaChrome.dim,
            .paragraphStyle: paragraph
        ]
        let cellW = bounds.width / 7
        for (index, name) in CalendarClock.weekdays.enumerated() {
            let rect = NSRect(x: CGFloat(index) * cellW, y: 28, width: cellW, height: 14)
            (name as NSString).draw(in: rect, withAttributes: attrs)
        }
    }

    /// Клетка дня. Пустые до и после месяца не рисуются и не нажимаются.
    private struct DayCell {
        var date: Date
        var inMonth: Bool
        var rect: NSRect
    }

    private func dayCells() -> [DayCell] {
        let header: CGFloat = 44
        let cellW = bounds.width / 7
        let cellH = max(8, (bounds.height - header) / 6)
        let weekday = CalendarClock.calendar.component(.weekday, from: month)
        let lead = (weekday + 5) % 7
        return (0..<42).map { index in
            let date = CalendarClock.calendar.date(byAdding: .day, value: index - lead, to: month) ?? month
            let rect = NSRect(
                x: CGFloat(index % 7) * cellW,
                y: header + CGFloat(index / 7) * cellH,
                width: cellW,
                height: cellH
            )
            let inMonth = CalendarClock.calendar.isDate(date, equalTo: month, toGranularity: .month)
            return DayCell(date: date, inMonth: inMonth, rect: rect)
        }
    }

    private func draw(_ cell: DayCell) {
        let day = CalendarClock.calendar.component(.day, from: cell.date)
        let today = CalendarClock.calendar.isDateInToday(cell.date)
        let chosen = selected.map { CalendarClock.sameDay($0, cell.date) } ?? false
        let radius = min(9, cell.rect.width / 2 - 3)
        let center = NSPoint(x: cell.rect.midX, y: cell.rect.minY + radius + 1)
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if chosen {
            IslandLook.accent.withAlphaComponent(0.28).setFill()
            ring.fill()
        }
        if today {
            IslandLook.accent.setStroke()
            ring.lineWidth = 1.5
            ring.stroke()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = UtkaChrome.font(12, weight: today ? .semibold : .medium)
        let textRect = NSRect(x: cell.rect.minX, y: center.y - 8, width: cell.rect.width, height: 16)
        ("\(day)" as NSString).draw(in: textRect, withAttributes: [
            .font: font,
            .foregroundColor: UtkaChrome.ink,
            .paragraphStyle: paragraph
        ])
        let mark = CalendarClock.startOfDay(cell.date)
        guard marked.contains(mark) else { return }
        let dot: CGFloat = 3
        var dotY = center.y + radius + 1
        if dotY + dot > cell.rect.maxY - 1 { dotY = cell.rect.maxY - dot - 1 }
        IslandLook.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: dotY, width: dot, height: dot)).fill()
    }
}

/// Строка очереди: время, заголовок и колокольчик, если заметка крякает.
private final class CalendarNoteRow: NSView {
    var onClick: (() -> Void)?
    private let timeLabel = UtkaChrome.label("", size: 12, weight: .medium)
    private let titleLabel = UtkaChrome.label("", size: 13, weight: .semibold)
    private let quackMark = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        quackMark.imageScaling = .scaleNone
        quackMark.imageAlignment = .alignCenter
        quackMark.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Кряк")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        addSubview(timeLabel)
        addSubview(titleLabel)
        addSubview(quackMark)
    }

    required init?(coder: NSCoder) { nil }

    /// ringing — срок наступил и заметку ещё не открыли.
    func show(time: String, title: String, quack: Bool, ringing: Bool) {
        timeLabel.stringValue = time
        titleLabel.stringValue = title
        timeLabel.textColor = ringing ? IslandLook.accent : UtkaChrome.dim
        titleLabel.textColor = UtkaChrome.ink
        quackMark.isHidden = !quack
        quackMark.contentTintColor = ringing ? IslandLook.accent : UtkaChrome.dim
        layer?.backgroundColor = (ringing ? IslandLook.accent.withAlphaComponent(0.28) : UtkaChrome.card).cgColor
    }

    override func layout() {
        super.layout()
        let mid = (bounds.height - 16) / 2
        timeLabel.frame = NSRect(x: 8, y: mid, width: 44, height: 16)
        quackMark.frame = NSRect(x: bounds.width - 22, y: mid, width: 16, height: 16)
        let titleX = timeLabel.frame.maxX + 6
        titleLabel.frame = NSRect(x: titleX, y: mid, width: max(20, quackMark.frame.minX - 6 - titleX), height: 16)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }
}

/// Тело раздела «Календарь»: месяц слева, очередь или редактор справа.
final class CalendarIslandView: NSView, NSTextViewDelegate {
    var onOpened: ((String) -> Void)?
    var onHold: ((Bool) -> Void)?
    var ringingID: String? {
        didSet {
            guard ringingID != oldValue else { return }
            queueDirty = true
            needsLayout = true
        }
    }

    private let model: CalendarModel
    private let month = MonthGrid()
    private let plus = calendarIconButton(symbol: "plus", tip: "Новая заметка", target: CalendarIslandView.holder, action: #selector(CalendarIslandView.addTapped))
    private let split = NSView()
    private let queue = NSScrollView()
    private let document = FlippedView()
    private let empty = UtkaChrome.label("Заметок нет", size: 13, color: UtkaChrome.dim)
    private let backButton = calendarIconButton(symbol: "chevron.left", tip: "Назад", target: CalendarIslandView.holder, action: #selector(CalendarIslandView.cancelTapped))
    private let dateLabel = UtkaChrome.label("", size: 13, weight: .semibold)
    private let hourField = ClockField(max: 23)
    private let minuteField = ClockField(max: 59)
    private let colon = UtkaChrome.label(":", size: 15, weight: .medium)
    private let titleField = NSTextField()
    private let bodyScroll = NSScrollView()
    private let bodyView = NSTextView()
    private let bodyHint = UtkaChrome.label("Текст", size: 13, color: UtkaChrome.dim)
    private let quackLabel = UtkaChrome.label("Крякер", size: 13, weight: .medium)
    private let quackSwitch = NSSwitch()
    private let saveButton = NSButton()
    private let deleteButton = calendarIconButton(symbol: "trash.fill", tip: "Удалить", target: CalendarIslandView.holder, action: #selector(CalendarIslandView.deleteTapped))
    private static let holder = NSObject()

    private var visibleMonth = CalendarClock.monthStart(Date())
    /// День, к которому прокрутили очередь. Список от этого не режется.
    private var focusDay: Date?
    /// Куда прокрутить после пересборки очереди.
    private var pendingScroll: Date?
    /// Верх первой заметки дня в ленте. Ключ — начало суток.
    private var dayAnchors: [Date: CGFloat] = [:]
    private var draftDay = CalendarClock.startOfDay(Date())
    private var editing: CalendarNote?
    private var editorOn = false
    private var queueDirty = true
    private var queueWidth: CGFloat = -1
    private var layingOut = false
    private var removePrompt: RemovePrompt?
    private var notesObserver: NSObjectProtocol?
    private var lookObserver: NSObjectProtocol?

    init(model: CalendarModel) {
        self.model = model
        super.init(frame: .zero)
        plus.target = self
        plus.action = #selector(addTapped)
        backButton.target = self
        backButton.action = #selector(cancelTapped)
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.image = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Удалить")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        month.onDay = { [weak self] day in self?.pick(day) }
        month.onMonth = { [weak self] step in self?.shiftMonth(step) }
        split.wantsLayer = true
        let clip = FlippedClipView()
        queue.contentView = clip
        queue.documentView = document
        queue.hasVerticalScroller = true
        queue.autohidesScrollers = true
        queue.drawsBackground = false
        queue.borderType = .noBorder
        empty.alignment = .center
        prepareEditor()
        addSubview(month)
        addSubview(plus)
        addSubview(split)
        addSubview(queue)
        addSubview(empty)
        editorViews().forEach { addSubview($0) }
        applyLook()
        applyMode()
        notesObserver = NotificationCenter.default.addObserver(
            forName: CalendarModel.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.notesChanged()
        }
        lookObserver = NotificationCenter.default.addObserver(
            forName: IslandLook.changed, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyLook()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let notesObserver { NotificationCenter.default.removeObserver(notesObserver) }
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
    }

    /// Открыть существующую заметку и заодно унять кряк.
    func open(id: String) {
        guard let note = model.notes.first(where: { $0.id == id }) else { return }
        showEditor(note)
    }

    /// Цвета текста и сетки. Окно островка само меняет оформление.
    func applyLook() {
        month.applyLook()
        plus.contentTintColor = UtkaChrome.ink
        backButton.contentTintColor = UtkaChrome.ink
        split.layer?.backgroundColor = UtkaChrome.dim.withAlphaComponent(0.28).cgColor
        empty.textColor = UtkaChrome.dim
        dateLabel.textColor = UtkaChrome.ink
        dateLabel.font = UtkaChrome.font(13, weight: .semibold)
        colon.textColor = UtkaChrome.ink
        colon.font = UtkaChrome.font(15, weight: .medium)
        hourField.tint()
        minuteField.tint()
        titleField.textColor = UtkaChrome.ink
        titleField.font = UtkaChrome.font(13)
        titleField.backgroundColor = UtkaChrome.card
        bodyView.textColor = UtkaChrome.ink
        bodyView.font = UtkaChrome.font(13)
        bodyView.insertionPointColor = UtkaChrome.ink
        bodyScroll.layer?.backgroundColor = UtkaChrome.card.cgColor
        bodyHint.textColor = UtkaChrome.dim
        quackLabel.textColor = UtkaChrome.ink
        quackLabel.font = UtkaChrome.font(13, weight: .medium)
        saveButton.font = UtkaChrome.font(13, weight: .medium)
        deleteButton.contentTintColor = UtkaChrome.ink
        queueDirty = true
        needsLayout = true
    }

    override func layout() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        super.layout()
        placeColumns()
        if editorOn {
            layoutEditor()
        } else if queueDirty || abs(queueWidth - queue.contentSize.width) > 0.5 {
            reloadQueue()
        }
    }

    /// Подсказка «Текст» не перехватывает щелчок: его получает поле.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === bodyHint { return bodyScroll }
        return hit
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    /// Поля редактора. Плюс и месяц остаются на месте.
    private func prepareEditor() {
        styleLine(titleField, placeholder: "Заголовок")
        titleField.target = self
        titleField.action = #selector(saveTapped)
        bodyScroll.borderType = .noBorder
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.wantsLayer = true
        bodyScroll.layer?.cornerRadius = 6
        bodyView.isRichText = false
        bodyView.isEditable = true
        bodyView.isSelectable = true
        bodyView.allowsUndo = true
        bodyView.drawsBackground = false
        bodyView.delegate = self
        bodyView.textContainerInset = NSSize(width: 4, height: 4)
        bodyView.isVerticallyResizable = true
        bodyView.isHorizontallyResizable = false
        bodyView.autoresizingMask = [.width]
        bodyView.textContainer?.widthTracksTextView = true
        bodyView.isAutomaticQuoteSubstitutionEnabled = false
        bodyScroll.documentView = bodyView
        styleText(saveButton, title: "Сохранить", action: #selector(saveTapped))
        dateLabel.alignment = .center
    }

    private func styleLine(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = UtkaChrome.font(13)
        field.textColor = UtkaChrome.ink
        field.backgroundColor = UtkaChrome.card
        field.isBordered = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.drawsBackground = true
    }

    private func styleText(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = UtkaChrome.font(13, weight: .medium)
        button.target = self
        button.action = action
    }

    private func editorViews() -> [NSView] {
        [backButton, dateLabel, hourField, colon, minuteField, titleField, bodyScroll, bodyHint, quackLabel, quackSwitch, saveButton, deleteButton]
    }

    private func placeColumns() {
        let left = min(268, max(180, bounds.width * 0.46))
        month.frame = NSRect(x: 0, y: 0, width: left, height: bounds.height)
        plus.frame = NSRect(x: left - 26, y: bounds.height - 26, width: 24, height: 24)
        split.frame = NSRect(x: left + 8, y: 6, width: 1, height: max(0, bounds.height - 12))
        let rightX = left + 16
        let right = NSRect(x: rightX, y: 0, width: max(40, bounds.width - rightX), height: bounds.height)
        queue.frame = right
        empty.frame = right
        refreshMonth()
    }

    /// Точки и подсветка дня. В редакторе подсвечен черновик, в очереди — день, к которому прокрутили.
    private func refreshMonth() {
        let marks = Set(model.notes.map { CalendarClock.startOfDay($0.at) })
        let chosen = editorOn ? draftDay : focusDay
        month.show(month: visibleMonth, selected: chosen, marked: marks)
    }

    private func shiftMonth(_ step: Int) {
        visibleMonth = CalendarClock.calendar.date(byAdding: .month, value: step, to: visibleMonth) ?? visibleMonth
        refreshMonth()
    }

    /// В редакторе щелчок ставит дату. В очереди прокручивает к первой заметке этого дня.
    private func pick(_ day: Date) {
        if editorOn {
            draftDay = day
            visibleMonth = CalendarClock.monthStart(day)
            refreshDateLabel()
            refreshMonth()
            return
        }
        focusDay = day
        refreshMonth()
        guard !queueDirty else {
            pendingScroll = day
            needsLayout = true
            return
        }
        scrollToDay(day)
    }

    /// Ставит первую заметку дня у верхнего края очереди. Пустой день очередь не двигает.
    private func scrollToDay(_ day: Date) {
        let key = CalendarClock.startOfDay(day)
        guard let top = dayAnchors[key] else { return }
        let clip = queue.contentView
        let limit = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(top, limit)))
        queue.reflectScrolledClipView(clip)
    }

    @objc private func addTapped() {
        let day = focusDay ?? CalendarClock.startOfDay(Date())
        showEditor(nil, day: day, time: Date().addingTimeInterval(600))
    }

    /// Редактор по щелчку на строке. Кряк стихает, как только заметка открыта.
    private func showEditor(_ note: CalendarNote) {
        showEditor(note, day: note.at, time: note.at)
    }

    private func showEditor(_ note: CalendarNote?, day: Date, time: Date) {
        editorOn = true
        editing = note
        draftDay = CalendarClock.startOfDay(day)
        visibleMonth = CalendarClock.monthStart(draftDay)
        let parts = CalendarClock.calendar.dateComponents([.hour, .minute], from: time)
        hourField.show(parts.hour ?? 0)
        minuteField.show(parts.minute ?? 0)
        titleField.stringValue = note?.title ?? ""
        bodyView.string = note?.body ?? ""
        bodyHint.isHidden = !(note?.body ?? "").isEmpty
        quackSwitch.state = (note?.quack ?? true) ? .on : .off
        refreshDateLabel()
        applyMode()
        refreshMonth()
        needsLayout = true
        if let note, note.quack, !note.acknowledged, note.at <= Date() {
            onOpened?(note.id)
        }
        window?.makeFirstResponder(titleField)
    }

    private func refreshDateLabel() {
        dateLabel.stringValue = CalendarClock.dayTitle(draftDay)
    }

    func textDidChange(_ notification: Notification) {
        bodyHint.isHidden = !bodyView.string.isEmpty
    }

    @objc private func cancelTapped() {
        closeEditor()
    }

    /// Пустые заголовок и текст вместе не пишем.
    @objc private func saveTapped() {
        guard editorOn else { return }
        guard let hour = hourField.clockNumber(), let minute = minuteField.clockNumber() else {
            NSSound.beep()
            return
        }
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = bodyView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !body.isEmpty else {
            NSSound.beep()
            return
        }
        guard let at = CalendarClock.combining(day: draftDay, hour: hour, minute: minute) else {
            NSSound.beep()
            return
        }
        let id = editing?.id ?? UUID().uuidString
        let kept = model.notes.first { $0.id == id }
        let sameSlot = kept?.at == at && kept?.quack == (quackSwitch.state == .on)
        let note = CalendarNote(
            id: id,
            title: title,
            body: body,
            at: at,
            quack: quackSwitch.state == .on,
            acknowledged: sameSlot ? (kept?.acknowledged ?? false) : false
        )
        editorOn = false
        editing = nil
        model.upsert(note)
        closeEditor()
    }

    @objc private func deleteTapped() {
        guard let id = editing?.id, removePrompt == nil else { return }
        onHold?(true)
        let prompt = RemovePrompt(text: "Удалить эту заметку?")
        removePrompt = prompt
        prompt.onChoose = { [weak self] drop in
            guard let self else { return }
            self.onHold?(false)
            self.removePrompt = nil
            guard drop else { return }
            self.editorOn = false
            self.editing = nil
            self.model.remove(id: id)
            self.closeEditor()
        }
        prompt.show(over: window)
    }

    private func closeEditor() {
        editorOn = false
        editing = nil
        window?.makeFirstResponder(nil)
        applyMode()
        refreshMonth()
        queueDirty = true
        needsLayout = true
    }

    private func applyMode() {
        editorViews().forEach { $0.isHidden = !editorOn }
        deleteButton.isHidden = !editorOn || editing == nil
        bodyHint.isHidden = !editorOn || !bodyView.string.isEmpty
        queue.isHidden = editorOn
        if editorOn { empty.isHidden = true }
    }

    private func notesChanged() {
        refreshMonth()
        guard !editorOn else { return }
        queueDirty = true
        needsLayout = true
    }

    /// Очередь всегда целиком: просрочено, сегодня, завтра, позже.
    private func grouped() -> [(title: String, notes: [CalendarNote])] {
        let now = Date()
        var buckets: [CalendarBucket: [CalendarNote]] = [:]
        for note in model.notes {
            buckets[CalendarClock.bucket(note.at, now: now), default: []].append(note)
        }
        return CalendarBucket.allCases.compactMap { bucket in
            let notes = (buckets[bucket] ?? []).sorted { $0.at < $1.at }
            guard !notes.isEmpty else { return nil }
            return (bucket.title, notes)
        }
    }

    private func reloadQueue() {
        queueDirty = false
        dayAnchors = [:]
        document.subviews.forEach { $0.removeFromSuperview() }
        let width = max(40, queue.contentSize.width)
        queueWidth = width
        let groups = grouped()
        empty.stringValue = model.loadError.isEmpty ? "Заметок нет" : model.loadError
        empty.isHidden = editorOn || !groups.isEmpty
        queue.isHidden = editorOn || groups.isEmpty
        guard !groups.isEmpty else { return }
        var y: CGFloat = 0
        for group in groups {
            let header = UtkaChrome.label(group.title, size: 11, weight: .semibold, color: UtkaChrome.dim)
            header.frame = NSRect(x: 2, y: y, width: width - 4, height: 16)
            document.addSubview(header)
            y += 18
            for note in group.notes {
                let day = CalendarClock.startOfDay(note.at)
                if dayAnchors[day] == nil { dayAnchors[day] = y }
                let row = CalendarNoteRow()
                row.frame = NSRect(x: 0, y: y, width: width, height: 28)
                let title = note.title.isEmpty ? oneLine(note.body, limit: 48) : note.title
                row.show(
                    time: CalendarClock.clockText(note.at),
                    title: title,
                    quack: note.quack,
                    ringing: note.id == ringingID
                )
                row.onClick = { [weak self] in self?.showEditor(note) }
                document.addSubview(row)
                y += 32
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, queue.contentView.bounds.height))
        guard let pendingScroll else { return }
        self.pendingScroll = nil
        scrollToDay(pendingScroll)
    }

    private func layoutEditor() {
        let area = queue.frame
        let x = area.minX
        let width = area.width
        var y = area.maxY - 26
        backButton.frame = NSRect(x: x, y: y, width: 22, height: 22)
        dateLabel.frame = NSRect(x: x + 26, y: y, width: max(40, width - 52), height: 22)
        y -= 30
        hourField.frame = NSRect(x: x, y: y, width: 40, height: 24)
        colon.frame = NSRect(x: hourField.frame.maxX, y: y, width: 12, height: 24)
        minuteField.frame = NSRect(x: colon.frame.maxX, y: y, width: 40, height: 24)
        quackLabel.sizeToFit()
        let switchSize = quackSwitch.fittingSize
        let switchW = max(32, switchSize.width)
        let switchH = max(18, switchSize.height)
        quackSwitch.frame = NSRect(x: x + width - switchW, y: y + (24 - switchH) / 2, width: switchW, height: switchH)
        let labelW = ceil(quackLabel.frame.width)
        quackLabel.frame = NSRect(x: quackSwitch.frame.minX - 6 - labelW, y: y + 3, width: labelW, height: 18)
        y -= 30
        titleField.frame = NSRect(x: x, y: y, width: width, height: 24)
        let buttonsY = area.minY
        let bodyTop = y - 6
        let bodyH = max(28, bodyTop - (buttonsY + 32))
        let bodyBottom = bodyTop - bodyH
        bodyScroll.frame = NSRect(x: x, y: bodyBottom, width: width, height: bodyH)
        bodyHint.frame = NSRect(x: x + 8, y: bodyScroll.frame.maxY - 22, width: width - 16, height: 18)
        let bodyWidth = max(40, bodyScroll.contentSize.width)
        bodyView.textContainer?.containerSize = NSSize(width: bodyWidth, height: CGFloat.greatestFiniteMagnitude)
        if bodyView.frame.width != bodyWidth { bodyView.frame.size.width = bodyWidth }
        let buttonW = min(120, max(96, width * 0.42))
        saveButton.frame = NSRect(x: x + width - buttonW + 6, y: buttonsY, width: buttonW, height: 26)
        deleteButton.frame = NSRect(x: x, y: buttonsY + 2, width: 22, height: 22)
    }
}
