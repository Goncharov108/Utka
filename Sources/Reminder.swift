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
/// сегодняшнего дня. Разнёс на два отдельных пикера: полноразмерный
/// календарь сверху и числовое поле времени со стрелками снизу.
final class AlarmPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let calendarPicker = NSDatePicker()
    private let timePicker = NSDatePicker()
    private var onPick: ((Date?) -> Void)?
    /// true, пока попап открыт. Курсор на поле времени часто уходит ниже
    /// границ островка, и жест наведения принял бы это за уход мыши —
    /// подписчик (панель заготовок) на это время держит островок открытым.
    var onPresenting: ((Bool) -> Void)?

    /// view — якорь попапа. initial — текущая дата будильника, если уже стоит.
    func show(from view: NSView, initial: Date?, onPick: @escaping (Date?) -> Void) {
        self.onPick = onPick
        let initialDate = initial ?? Date().addingTimeInterval(600)

        calendarPicker.datePickerStyle = .clockAndCalendar
        calendarPicker.datePickerElements = [.yearMonthDay]
        calendarPicker.datePickerMode = .single
        calendarPicker.minDate = Calendar.current.startOfDay(for: Date())
        calendarPicker.dateValue = initialDate
        calendarPicker.sizeToFit()

        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = [.hourMinute]
        timePicker.dateValue = initialDate
        timePicker.sizeToFit()

        let pad: CGFloat = 12
        let calSize = calendarPicker.frame.size
        let width = max(calSize.width, 200) + pad * 2
        let timeLabel = UtkaChrome.label("Время", size: 12, color: UtkaChrome.dim)
        timeLabel.sizeToFit()
        let buttonH: CGFloat = 28
        let height = calSize.height + pad * 3 + timeLabel.frame.height + timePicker.frame.height + buttonH

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var y = height - pad - calSize.height
        calendarPicker.frame = NSRect(x: (width - calSize.width) / 2, y: y, width: calSize.width, height: calSize.height)
        root.addSubview(calendarPicker)

        y -= pad + timeLabel.frame.height
        timeLabel.frame = NSRect(x: pad, y: y + 2, width: 60, height: timeLabel.frame.height)
        root.addSubview(timeLabel)
        timePicker.frame = NSRect(x: pad + 64, y: y - 2, width: timePicker.frame.width, height: timePicker.frame.height)
        root.addSubview(timePicker)

        y = pad
        let setButton = NSButton(title: "Поставить", target: self, action: #selector(setTapped))
        setButton.bezelStyle = .rounded
        setButton.frame = NSRect(x: pad, y: y, width: 94, height: buttonH)
        root.addSubview(setButton)
        if initial != nil {
            let clearButton = NSButton(title: "Снять", target: self, action: #selector(clearTapped))
            clearButton.bezelStyle = .rounded
            clearButton.frame = NSRect(x: pad + 100, y: y, width: 94, height: buttonH)
            root.addSubview(clearButton)
        }
        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        onPresenting?(true)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        onPresenting?(false)
    }

    /// День берём с календаря, час и минуту — с поля времени.
    private var combinedDate: Date {
        let time = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        return Calendar.current.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: calendarPicker.dateValue
        ) ?? calendarPicker.dateValue
    }

    // Сначала закрыть попап и только потом применить выбор: onPick обычно
    // меняет модель и сразу перестраивает список заметок, снимая со
    // экрана ту самую строку, к которой попап был приколот. Если это
    // происходит раньше закрытия, попап остаётся «висеть» без якоря и
    // не сообщает через onPresenting, что открытие закончилось — островок
    // потом никогда не закрывается сам.
    @objc private func setTapped() {
        let picked = combinedDate
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

    /// Один раз крякнуть и ничего не услышать — не напоминание. Повторяем,
    /// пока заметку не откроют, с интервалом из настроек крякера.
    private func startQuacking() {
        guard QuackerPrefs.enabled else {
            stopQuacking()
            return
        }
        quack()
        quackTimer?.invalidate()
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
