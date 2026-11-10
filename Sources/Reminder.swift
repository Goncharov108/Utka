import AppKit

/// Настройки крякера — напоминателя по заметкам. Живут в UserDefaults этого Мака.
enum QuackerPrefs {
    /// Секунды или минуты между повторными кряками.
    enum Unit: Int, CaseIterable {
        case seconds, minutes

        /// Подпись у сегментов на странице «Календарь».
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

    /// Крякер включён. Без ключа — да.
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

    /// Крякер или интервал сменили — ReminderEngine подтягивается.
    static let changed = Notification.Name("QuackerPrefsChanged")
}

/// Часы или минуты: при входе выделяет всё, принимает только цифры.
final class ClockField: NSTextField, NSTextFieldDelegate {
    private let maxValue: Int

    init(max: Int) {
        maxValue = max
        super.init(frame: .zero)
        delegate = self
        cell?.wraps = false
        cell?.isScrollable = true
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        alignment = .center
        tint()
    }

    required init?(coder: NSCoder) { nil }

    /// Ставит две цифры. Кривое значение при сохранении не примется.
    func show(_ value: Int) {
        let clamped = min(max(0, value), maxValue)
        stringValue = String(format: "%02d", clamped)
        tint()
    }

    /// Чернила и гротеск под текущую тему, цифры не трогает.
    func tint() {
        textColor = UtkaChrome.ink
        font = UtkaChrome.font(15, weight: .medium)
    }

    /// Число в диапазоне, иначе nil. Ноль допустим.
    func clockNumber() -> Int? {
        let typed = Int(stringValue.trimmingCharacters(in: .whitespaces))
        guard let typed, (0...maxValue).contains(typed) else { return nil }
        return typed
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.currentEditor()?.selectAll(nil) } }
        return ok
    }

    func controlTextDidChange(_ obj: Notification) {
        let digits = stringValue.filter { $0.isASCII && $0.isNumber }
        let trimmed = String(digits.suffix(2))
        if trimmed != stringValue { stringValue = trimmed }
    }
}

/// Крякает по заметке календаря, когда её время наступило.
/// Если Мак спал — напоминает сразу при пробуждении: проверка смотрит, что срок уже прошёл.
final class ReminderEngine {
    /// Меняется, когда начинает или перестаёт кричать очередная заметка.
    var onRingingChanged: ((String?) -> Void)?

    private(set) var ringingID: String?
    private let calendar: CalendarModel
    private var checkTimer: Timer?
    private var quackTimer: Timer?

    init(calendar: CalendarModel) {
        self.calendar = calendar
    }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(recheck), name: NSWorkspace.didWakeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged), name: QuackerPrefs.changed, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(recheck), name: CalendarModel.changed, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(recheck), name: IslandSection.orderChanged, object: nil
        )
        check()
    }

    /// Раздел спрятан — кряк жив. Снят из библиотеки — молчит, файл заметок не трогаем.
    private func calendarInstalled() -> Bool {
        SectionBoard.order.contains { $0.id == "calendar" }
    }

    @objc private func recheck() {
        check()
    }

    /// Выключили крякер или сменили интервал — сразу пересчитать.
    @objc private func prefsChanged() {
        if !QuackerPrefs.enabled {
            silence()
            return
        }
        if ringingID != nil {
            startQuacking()
        } else {
            check()
        }
    }

    /// Ближайшая заметка с «Крякнуть», срок которой уже наступил и её ещё не открывали.
    private func due(_ now: Date) -> CalendarNote? {
        guard QuackerPrefs.enabled, calendarInstalled() else { return nil }
        return calendar.notes
            .filter { $0.quack && !$0.acknowledged && $0.at <= now }
            .sorted { $0.at < $1.at }
            .first
    }

    private func check() {
        guard QuackerPrefs.enabled, calendarInstalled() else {
            silence()
            return
        }
        let next = due(Date())
        if let next {
            guard ringingID != next.id else { return }
            ringingID = next.id
            onRingingChanged?(next.id)
            startQuacking()
        } else if ringingID != nil {
            silence()
        }
    }

    /// Открыли заметку — крик прекращается.
    func acknowledge(id: String) {
        calendar.acknowledge(id: id)
        check()
    }

    private func silence() {
        guard ringingID != nil || quackTimer != nil else { return }
        ringingID = nil
        onRingingChanged?(nil)
        stopQuacking()
    }

    /// Один раз крякнуть. Если повтор включён — дальше с интервалом, пока заметку не откроют.
    private func startQuacking() {
        guard QuackerPrefs.enabled, calendarInstalled() else {
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
    /// Кряк обязан быть услышан, а не замолчать из-за выбранного выхода.
    private func quack() {
        guard QuackerPrefs.enabled, calendarInstalled() else { return }
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

