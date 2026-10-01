import AppKit

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
final class AlarmPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let picker = NSDatePicker()
    private var onPick: ((Date?) -> Void)?

    /// view — якорь попапа. initial — текущая дата будильника, если уже стоит.
    func show(from view: NSView, initial: Date?, onPick: @escaping (Date?) -> Void) {
        self.onPick = onPick
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 150))
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate = Date().addingTimeInterval(-60)
        picker.dateValue = initial ?? Date().addingTimeInterval(600)
        picker.frame = NSRect(x: 10, y: 44, width: 200, height: 96)
        root.addSubview(picker)
        let setButton = NSButton(title: "Поставить", target: self, action: #selector(setTapped))
        setButton.bezelStyle = .rounded
        setButton.frame = NSRect(x: 10, y: 8, width: 94, height: 28)
        root.addSubview(setButton)
        if initial != nil {
            let clearButton = NSButton(title: "Снять", target: self, action: #selector(clearTapped))
            clearButton.bezelStyle = .rounded
            clearButton.frame = NSRect(x: 112, y: 8, width: 94, height: 28)
            root.addSubview(clearButton)
        }
        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    @objc private func setTapped() {
        onPick?(picker.dateValue)
        popover.performClose(nil)
    }

    @objc private func clearTapped() {
        onPick?(nil)
        popover.performClose(nil)
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
        check()
    }

    @objc private func wokeUp() {
        check()
    }

    /// Заметка с ближайшим наступившим и ещё не открытым будильником, если есть.
    private func due(_ now: Date) -> Preset? {
        model.texts
            .filter { ($0.dueAt.map { $0 <= now } ?? false) && $0.alarmAcknowledged != true }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            .first
    }

    private func check() {
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

    private func startQuacking() {
        quack()
        quackTimer?.invalidate()
        let timer = Timer(timeInterval: 45, repeats: true) { [weak self] _ in self?.quack() }
        RunLoop.main.add(timer, forMode: .common)
        quackTimer = timer
    }

    private func stopQuacking() {
        quackTimer?.invalidate()
        quackTimer = nil
    }

    /// Два коротких звука подряд — похоже на «кря-кря». Положите в Resources/quack.caf
    /// (или .wav) настоящую запись кряканья утки — тогда играть будет она вместо заглушки.
    private func quack() {
        if let url = Bundle.main.url(forResource: "quack", withExtension: "caf")
            ?? Bundle.main.url(forResource: "quack", withExtension: "wav"),
           let sound = NSSound(contentsOf: url, byReference: true) {
            sound.play()
            return
        }
        NSSound(named: "Pop")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            NSSound(named: "Pop")?.play()
        }
    }
}
