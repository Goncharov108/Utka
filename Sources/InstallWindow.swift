import AppKit

/// Короткое окно установки: согласие, полоска шагов, ошибка без закрытия утки.
final class InstallWindow: NSObject {
    private static var current: InstallWindow?

    /// Показывает окно поверх настроек. onDismiss — отмена или закрытие ошибки, утка жива.
    static func present(over host: NSWindow?, onDismiss: @escaping () -> Void) {
        let panel = InstallWindow(onDismiss: onDismiss)
        current = panel
        panel.show(over: host)
    }

    private let window: InstallHost
    private let card = UtkaPanelChrome()
    private let message = UtkaChrome.label("", size: 13)
    private let caption = UtkaChrome.label("", size: 13)
    private let percent = UtkaChrome.label("", size: 13, weight: .semibold)
    private let track = InstallTrack()
    private let agreeButton = NSButton()
    private let cancelButton = NSButton()
    private var onDismiss: (() -> Void)?
    private var lookToken: NSObjectProtocol?
    private var escapeMonitor: Any?
    private var timer: Timer?
    private var mode: Mode = .ask
    private var mark: InstallMark?
    private var skipped: Set<InstallMark> = []
    private var shown: Double = 0
    private var ceiling: Double = 0
    private var closed = false

    private init(onDismiss: @escaping () -> Void) {
        window = InstallHost(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.onDismiss = onDismiss
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.onEscape = { [weak self] in self?.escape() }
        window.contentView = card

        message.stringValue = "Утка закроется в конце. Сборка займёт время: на экране будет полоска, потом утка откроется сама."
        message.maximumNumberOfLines = 4
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        percent.alignment = .right
        card.addSubview(message)
        card.addSubview(caption)
        card.addSubview(percent)
        card.addSubview(track)
        style(agreeButton, title: "Установить", action: #selector(confirm))
        style(cancelButton, title: "Отмена", action: #selector(cancel))
        agreeButton.keyEquivalent = "\r"
        card.addSubview(agreeButton)
        card.addSubview(cancelButton)

        lookToken = UtkaChrome.track(window) { [weak self] in
            self?.applyLook()
        }
    }

    /// Ставит окно по центру настроек и делает его ключевым.
    private func show(over host: NSWindow?) {
        let size = window.frame.size
        let area = host?.frame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        window.setFrame(NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: false)
        layoutCard()
        window.orderFrontRegardless()
        window.makeKey()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.window === self?.window else { return event }
            self?.escape()
            return nil
        }
    }

    /// Текст и полоска под текущий вид. Фон обновляет само стекло.
    private func applyLook() {
        card.apply()
        message.textColor = UtkaChrome.ink
        caption.textColor = UtkaChrome.ink
        percent.textColor = UtkaChrome.ink
        agreeButton.appearance = window.appearance
        cancelButton.appearance = window.appearance
        track.needsDisplay = true
    }

    /// Согласие: то же окно, полоска, сборка ещё при живой утке.
    @objc private func confirm() {
        guard mode == .ask else { return }
        mode = .progress
        mark = .code
        shown = 0
        ceiling = InstallMark.code.percent - 1
        caption.stringValue = InstallMark.code.title
        paint()
        layoutCard()
        startCreep()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runWork()
        }
    }

    /// Отмена и «Закрыть» ничего не ставят. Утка остаётся.
    @objc private func cancel() {
        escape()
    }

    /// Escape закрывает вопрос и ошибку. Во время сборки утку не бросает.
    private func escape() {
        guard mode != .progress else { return }
        dismiss()
    }

    /// Снимает токен вида и говорит настройкам, что окно ушло.
    private func dismiss() {
        guard !closed else { return }
        closed = true
        timer?.invalidate()
        timer = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let lookToken {
            NotificationCenter.default.removeObserver(lookToken)
            self.lookToken = nil
        }
        window.orderOut(nil)
        let done = onDismiss
        onDismiss = nil
        InstallWindow.current = nil
        done?()
    }

    /// Сначала проверка папки, потом сборка рядом. Ошибка остаётся в этом окне.
    private func runWork() {
        let error = AppUpdate.prepareInstall()
        if let error {
            DispatchQueue.main.async { [weak self] in self?.fail(error) }
            return
        }
        DispatchQueue.main.async { [weak self] in self?.land(.code) }
        let before = AppUpdate.driverFingerprint()
        let built = AppUpdate.runStagedBuild { token in
            DispatchQueue.main.async { [weak self] in self?.take(token) }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let built {
                self.fail(built)
                return
            }
            self.openNew(driverBefore: before)
        }
    }

    /// Короткий текст сбоя. Утка не закрывается и бандл не подменяется.
    private func fail(_ text: String) {
        guard mode != .error, !closed else { return }
        mode = .error
        timer?.invalidate()
        timer = nil
        message.stringValue = text
        layoutCard()
    }

    /// «Открываю» успевает отрисоваться, затем процесс уступает место новой утке.
    private func openNew(driverBefore: String) {
        guard mode == .progress else { return }
        mark = .open
        shown = 100
        ceiling = 100
        caption.stringValue = InstallMark.open.title
        paint()
        window.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mode == .progress else { return }
            guard AppUpdate.startHandoff(driverBefore: driverBefore) else {
                self.fail("Не удалось открыть новую утку")
                return
            }
            NSApp.terminate(nil)
        }
    }

    /// Шаг со скрипта: previous, arm64, intel, sign или skip.
    private func take(_ token: String) {
        guard mode == .progress, shown < 100 else { return }
        if token.hasPrefix("skip ") {
            skip(String(token.dropFirst("skip ".count)))
            return
        }
        guard let step = InstallMark(rawValue: token) else { return }
        begin(step)
    }

    /// Команда шага кончилась: число встаёт ровно на его отметку.
    private func land(_ step: InstallMark) {
        guard mode == .progress else { return }
        mark = step
        shown = step.percent
        ceiling = step.percent
        caption.stringValue = step.title
        paint()
    }

    /// Новый шаг. Прошлый, если он не пропущен, получает свою отметку.
    private func begin(_ step: InstallMark) {
        if let mark, mark != step, !skipped.contains(mark) {
            shown = mark.percent
            ceiling = mark.percent
        }
        if mark == step {
            paint()
            return
        }
        mark = step
        ceiling = step.percent - 1
        if ceiling < shown { ceiling = shown }
        caption.stringValue = step.title
        paint()
    }

    /// Архитектура не собралась: её процент не ставим, потолок у следующего живого шага.
    private func skip(_ name: String) {
        guard let step = InstallMark(rawValue: name) else { return }
        skipped.insert(step)
        guard mark == step, let next = step.next, next != .open else { return }
        mark = next
        let cap = next.percent - 1
        ceiling = cap < shown ? shown : cap
        caption.stringValue = next.title
        paint()
    }

    /// На длинном шаге доля ползёт и не доходит до отметки, пока команда не кончилась.
    private func startCreep() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard mode == .progress, shown < ceiling else { return }
        shown = min(ceiling, shown + 0.12)
        paint()
    }

    /// Целое число процентов и ширина заливки.
    private func paint() {
        percent.stringValue = "\(Int(shown))%"
        track.fraction = CGFloat(min(1, max(0, shown / 100)))
    }

    /// Кнопка того же гротеска, что и остальное окно.
    private func style(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = UtkaChrome.font(13, weight: .medium)
        button.target = self
        button.action = action
        button.sizeToFit()
    }

    /// Ширина по подписи, без накопления кадра.
    private func buttonWidth(_ button: NSButton) -> CGFloat {
        button.sizeToFit()
        return ceil(button.fittingSize.width) + 8
    }

    /// Вопрос, полоска или ошибка в том же кадре.
    private func layoutCard() {
        let width = window.frame.width
        let pad: CGFloat = 20
        let buttonH: CGFloat = 28
        let buttonY: CGFloat = 20
        let progress = mode == .progress
        message.isHidden = progress
        caption.isHidden = !progress
        percent.isHidden = !progress
        track.isHidden = !progress
        if progress {
            let percentWidth: CGFloat = 52
            percent.frame = NSRect(x: width - pad - percentWidth, y: 108, width: percentWidth, height: 22)
            caption.frame = NSRect(x: pad, y: 108, width: percent.frame.minX - pad - 8, height: 22)
            track.frame = NSRect(x: pad, y: 78, width: width - pad * 2, height: 6)
            agreeButton.isHidden = true
            cancelButton.isHidden = true
            return
        }
        message.frame = NSRect(x: pad, y: 64, width: width - pad * 2, height: 96)
        if mode == .error {
            agreeButton.isHidden = true
            cancelButton.isHidden = false
            cancelButton.title = "Закрыть"
            let widthButton = buttonWidth(cancelButton)
            cancelButton.frame = NSRect(x: width - pad - widthButton, y: buttonY, width: widthButton, height: buttonH)
            return
        }
        agreeButton.isHidden = false
        cancelButton.isHidden = false
        cancelButton.title = "Отмена"
        let agreeW = buttonWidth(agreeButton)
        let cancelW = buttonWidth(cancelButton)
        agreeButton.frame = NSRect(x: width - pad - agreeW, y: buttonY, width: agreeW, height: buttonH)
        cancelButton.frame = NSRect(x: agreeButton.frame.minX - 8 - cancelW, y: buttonY, width: cancelW, height: buttonH)
    }
}

/// Отметки полоски. Пропущенная архитектура своей отметки не получает.
private enum InstallMark: String {
    case code
    case previous
    case arm64
    case intel
    case sign
    case open

    var title: String {
        switch self {
        case .code: return "Код забран"
        case .previous: return "Прошлая копия"
        case .arm64: return "Собираю Apple Silicon"
        case .intel: return "Собираю Intel"
        case .sign: return "Подпись"
        case .open: return "Открываю"
        }
    }

    var percent: Double {
        switch self {
        case .code: return 8
        case .previous: return 18
        case .arm64: return 55
        case .intel: return 82
        case .sign: return 92
        case .open: return 100
        }
    }

    /// Следующий шаг в списке. Пропуск перепрыгивает на него, если он живой.
    var next: InstallMark? {
        switch self {
        case .code: return .previous
        case .previous: return .arm64
        case .arm64: return .intel
        case .intel: return .sign
        case .sign: return .open
        case .open: return nil
        }
    }
}

/// Вопрос и ошибка закрываются по Escape. Сборка — нет.
private final class InstallHost: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Полоска установки: дорожка карточки, заливка выбранного акцента.
private final class InstallTrack: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        UtkaChrome.card.setFill()
        track.fill()
        let width = bounds.width * min(1, max(0, fraction))
        guard width > 0.5 else { return }
        let fillRect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        IslandLook.accent.setFill()
        fill.fill()
    }
}

/// Вопрос, полоска или текст ошибки.
private enum Mode {
    case ask
    case progress
    case error
}
