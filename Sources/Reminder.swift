import AppKit

/// Настройки крякера — напоминателя по заметкам. Живут в UserDefaults этого Мака.
enum QuackerPrefs {
    /// Секунды или минуты между повторными кряками.
    enum Unit: Int, CaseIterable {
        case seconds, minutes

        /// Подпись у сегментов на странице «Закрепы».
        var title: String {
            switch self {
            case .seconds: return "секунд"
            case .minutes: return "минут"
            }
        }

        /// Секунд в одной единице.
        var seconds: TimeInterval {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            }
        }
    }

    private enum Key: String {
        case enabled = "quackerEnabled"
        case repeats = "quackerRepeats"
        case intervalCount = "quackerIntervalCount"
        case intervalUnit = "quackerIntervalUnit"
    }

    /// Допустимое число единиц интервала.
    static let countRange = 1...999

    /// Крякер включён. Без ключа — да, как раньше: будильник у заметок был всегда.
    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.enabled.rawValue) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Key.enabled.rawValue)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.enabled.rawValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Повторять кряк, пока заметку не откроют. Без ключа — да.
    static var repeats: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.repeats.rawValue) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Key.repeats.rawValue)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.repeats.rawValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Сколько единиц ждать между кряками. Без ключа — 30. Пустое и ноль не принимаются.
    static var intervalCount: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: Key.intervalCount.rawValue)
            return countRange.contains(stored) ? stored : 30
        }
        set {
            guard countRange.contains(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: Key.intervalCount.rawValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Единица интервала. Без ключа — секунды.
    static var intervalUnit: Unit {
        get {
            (UserDefaults.standard.object(forKey: Key.intervalUnit.rawValue) as? Int)
                .flatMap(Unit.init(rawValue:)) ?? .seconds
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Key.intervalUnit.rawValue)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Пауза между кряками в секундах.
    static var intervalSeconds: TimeInterval {
        TimeInterval(intervalCount) * intervalUnit.seconds
    }

    /// Крякер или интервал сменили — кнопки будильника и ReminderEngine подтягиваются.
    static let changed = Notification.Name("QuackerPrefsChanged")
}

/// «Сегодня в 14:30» или «1 окт в 14:30» — коротко, под строку заметки.
func alarmLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    if Calendar.current.isDateInToday(date) {
        formatter.dateFormat = "сегодня в HH:mm"
    } else if Calendar.current.isDateInTomorrow(date) {
        formatter.dateFormat = "завтра в HH:mm"
    } else {
        formatter.dateFormat = "d MMM в HH:mm"
    }
    return formatter.string(from: date)
}

/// Всплывающий выбор даты и времени для будильника заметки.
/// Один и тот же попап годится и для новой заметки, и для правки существующей.
///
/// Календарь и часы в одном узком виджете (.clockAndCalendar с обоими
/// элементами) не помещались — пропадала шапка с месяцем и подсветка
/// сегодняшнего дня. Снизу одна строка: часы, минуты и плюс.
final class AlarmPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let calendarPicker = NSDatePicker()
    private let hourField = NSTextField()
    private let minuteField = NSTextField()
    private var fallbackHour = 0
    private var fallbackMinute = 0
    private var onPick: ((Date?) -> Void)?
    /// true, пока попап открыт. Курсор на поле времени часто уходит ниже
    /// границ островка, и жест наведения принял бы это за уход мыши —
    /// подписчик (панель заготовок) на это время держит островок открытым.
    var onPresenting: ((Bool) -> Void)?

    /// view — якорь попапа. initial — текущая дата будильника, если уже стоит.
    func show(from view: NSView, initial: Date?, onPick: @escaping (Date?) -> Void) {
        self.onPick = onPick
        let initialDate = initial ?? Date().addingTimeInterval(600)
        let canClear = initial != nil

        let parts = Calendar.current.dateComponents([.hour, .minute], from: initialDate)
        fallbackHour = parts.hour ?? 0
        fallbackMinute = parts.minute ?? 0
        prepareCalendar(initialDate)
        styleClock(hourField, fallbackHour)
        styleClock(minuteField, fallbackMinute)

        let pad: CGFloat = 12
        let gap: CGFloat = 12
        let rowH: CGFloat = 26
        // Сетка дней не растягивается: строка времени ровно по её ширине.
        let calSize = calendarPicker.fittingSize
        let contentW = ceil(calSize.width)
        let width = contentW + pad * 2
        let height = pad + calSize.height + gap + rowH + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let calendarY = height - pad - calSize.height
        calendarPicker.frame = NSRect(x: pad, y: calendarY, width: contentW, height: calSize.height)
        root.addSubview(calendarPicker)
        placeClockRow(in: root, x: pad, y: pad, width: contentW, height: rowH, canClear: canClear)

        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        onPresenting?(true)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    /// Календарь без системной обводки и focus ring — иначе синяя «рамка в рамке».
    private func prepareCalendar(_ date: Date) {
        calendarPicker.datePickerStyle = .clockAndCalendar
        calendarPicker.datePickerElements = [.yearMonthDay]
        calendarPicker.datePickerMode = .single
        calendarPicker.minDate = Calendar.current.startOfDay(for: Date())
        calendarPicker.dateValue = date
        calendarPicker.isBordered = false
        calendarPicker.drawsBackground = false
        calendarPicker.focusRingType = .none
        if let cell = calendarPicker.cell as? NSDatePickerCell {
            cell.drawsBackground = false
            cell.backgroundColor = .clear
        }
        // У части сборок macOS обводка остаётся на слое ячейки — гасим явно.
        calendarPicker.wantsLayer = true
        calendarPicker.layer?.borderWidth = 0
        calendarPicker.layer?.borderColor = NSColor.clear.cgColor
        calendarPicker.sizeToFit()
    }

    /// Две цифры без рамки и без синей подсветки системного пикера.
    private func styleClock(_ field: NSTextField, _ value: Int) {
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = UtkaChrome.font(17, weight: .medium)
        field.textColor = UtkaChrome.ink
        field.alignment = .center
        field.stringValue = String(format: "%02d", value)
    }

    /// Одна строка на ширину календаря: цифры слева, плюс в конце.
    private func placeClockRow(in root: NSView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, canClear: Bool) {
        let digitW = clockDigitWidth()
        let digitH = ceil(hourField.fittingSize.height)
        let colon = UtkaChrome.label(":", size: 17, weight: .medium)
        colon.sizeToFit()
        let colonW = ceil(colon.fittingSize.width)
        let mid = y + (height - digitH) / 2

        hourField.frame = NSRect(x: x, y: mid, width: digitW, height: digitH)
        colon.frame = NSRect(x: x + digitW, y: mid, width: colonW, height: digitH)
        minuteField.frame = NSRect(x: x + digitW + colonW, y: mid, width: digitW, height: digitH)
        root.addSubview(hourField)
        root.addSubview(colon)
        root.addSubview(minuteField)

        let plus = makePlusButton()
        plus.frame = NSRect(x: x + width - height, y: y, width: height, height: height)
        root.addSubview(plus)

        guard canClear else { return }
        let clear = makeClearButton()
        let clearW = ceil(clear.fittingSize.width)
        clear.frame = NSRect(
            x: plus.frame.minX - 8 - clearW,
            y: y + (height - clear.fittingSize.height) / 2,
            width: clearW,
            height: ceil(clear.fittingSize.height)
        )
        root.addSubview(clear)
    }

    /// Ширина двух цифр текущим шрифтом часов.
    private func clockDigitWidth() -> CGFloat {
        let font = hourField.font ?? UtkaChrome.font(17, weight: .medium)
        let measured = ("00" as NSString).size(withAttributes: [.font: font]).width
        return ceil(measured) + 6
    }

    /// Плюс, как у новой заметки. Он и ставит будильник.
    private func makePlusButton() -> NSButton {
        let button = NSButton()
        button.title = ""
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Поставить")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.imagePosition = .imageOnly
        button.bezelStyle = .circular
        button.contentTintColor = UtkaChrome.ink
        button.target = self
        button.action = #selector(setTapped)
        button.toolTip = "Поставить"
        return button
    }

    /// Короткое «снять» между временем и плюсом, если будильник уже стоит.
    private func makeClearButton() -> NSButton {
        let button = NSButton(title: "снять", target: self, action: #selector(clearTapped))
        button.isBordered = false
        button.font = UtkaChrome.font(13, weight: .medium)
        button.contentTintColor = UtkaChrome.dim
        let title = NSAttributedString(
            string: "снять",
            attributes: [
                .font: UtkaChrome.font(13, weight: .medium),
                .foregroundColor: UtkaChrome.dim
            ]
        )
        button.attributedTitle = title
        return button
    }

    func popoverDidClose(_ notification: Notification) {
        onPresenting?(false)
    }

    /// День берём с календаря, час и минуту — с двух полей. Пустое и кривое не принимаем.
    private var combinedDate: Date? {
        guard let hour = strictClock(hourField, max: 23), let minute = strictClock(minuteField, max: 59) else {
            return nil
        }
        return Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: calendarPicker.dateValue
        ) ?? calendarPicker.dateValue
    }

    /// Число в диапазоне, иначе nil. Ноль для часа и минуты допустим.
    private func strictClock(_ field: NSTextField, max: Int) -> Int? {
        let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces))
        guard let typed, (0...max).contains(typed) else { return nil }
        return typed
    }

    // Сначала закрыть попап и только потом применить выбор: onPick обычно
    // меняет модель и сразу перестраивает список заметок, снимая со
    // экрана ту самую строку, к которой попап был приколот. Если это
    // происходит раньше закрытия, попап остаётся «висеть» без якоря и
    // не сообщает через onPresenting, что открытие закончилось — островок
    // потом никогда не закрывается сам.
    @objc private func setTapped() {
        guard let picked = combinedDate else {
            styleClock(hourField, fallbackHour)
            styleClock(minuteField, fallbackMinute)
            return
        }
        popover.performClose(nil)
        onPresenting?(false)
        onPick?(picked)
    }

    @objc private func clearTapped() {
        popover.performClose(nil)
        onPresenting?(false)
        onPick?(nil)
    }
}

/// Следит за будильниками у заметок и крякает, когда срок наступил.
/// Если Мак спал или был выключен — напоминает сразу при пробуждении,
/// а не молчит задним числом: проверка идёт по факту «время уже прошло»,
/// без разницы, насколько именно прошло.
final class ReminderEngine {
    /// Меняется, когда начинает или перестаёт кричать очередная заметка.
    var onRingingChanged: ((String?) -> Void)?

    private(set) var ringingID: String?
    private let model: PresetsModel
    private var checkTimer: Timer?
    private var quackTimer: Timer?

    init(model: PresetsModel) {
        self.model = model
    }

    func start() {
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: QuackerPrefs.changed, object: nil
        )
        check()
    }

    @objc private func wokeUp() {
        check()
    }

    /// Выключили крякер или сменили интервал — сразу пересчитать.
    @objc private func prefsChanged() {
        if !QuackerPrefs.enabled {
            if ringingID != nil {
                ringingID = nil
                onRingingChanged?(nil)
                stopQuacking()
            }
            return
        }
        if ringingID != nil {
            startQuacking()
        } else {
            check()
        }
    }

    /// Заметка с ближайшим наступившим и ещё не открытым будильником, если есть.
    private func due(_ now: Date) -> Preset? {
        model.texts
            .filter { ($0.dueAt.map { $0 <= now } ?? false) && $0.alarmAcknowledged != true }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            .first
    }

    private func check() {
        guard QuackerPrefs.enabled else {
            if ringingID != nil {
                ringingID = nil
                onRingingChanged?(nil)
                stopQuacking()
            }
            return
        }
        let next = due(Date())
        if let next {
            guard ringingID != next.id else { return }
            ringingID = next.id
            onRingingChanged?(next.id)
            startQuacking()
        } else if ringingID != nil {
            ringingID = nil
            onRingingChanged?(nil)
            stopQuacking()
        }
    }

    /// Открыли заметку — крик прекращается, заметка помечается прочитанной.
    func acknowledge(id: String) {
        model.acknowledgeAlarm(id: id)
        guard ringingID == id else { return }
        ringingID = nil
        onRingingChanged?(nil)
        stopQuacking()
        check()
    }

    /// Один раз крякнуть. Если повтор включён — дальше с интервалом, пока заметку не откроют.
    private func startQuacking() {
        guard QuackerPrefs.enabled else {
            stopQuacking()
            return
        }
        quackTimer?.invalidate()
        quackTimer = nil
        quack()
        guard QuackerPrefs.repeats else { return }
        let timer = Timer(timeInterval: QuackerPrefs.intervalSeconds, repeats: true) { [weak self] _ in
            self?.quack()
        }
        RunLoop.main.add(timer, forMode: .common)
        quackTimer = timer
    }

    private func stopQuacking() {
        quackTimer?.invalidate()
        quackTimer = nil
    }

    /// Играет напрямую в физические колонки Мака — не в «Утка звук» и не
    /// туда, куда сейчас ведёт системный выход (наушники, Bluetooth и т.д.).
    /// Будильник обязан быть услышан, а не замолчать из-за выбранного выхода.
    private func quack() {
        guard QuackerPrefs.enabled else { return }
        if let url = Bundle.main.url(forResource: "quack", withExtension: "mp3") {
            AudioOutput.shared.playThroughSpeakers(url)
            return
        }
        NSSound(named: "Pop")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NSSound(named: "Pop")?.play()
        }
    }
}
