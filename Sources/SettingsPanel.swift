import AppKit

/// Окно настроек. Открывается кликом по утке на островке.
final class SettingsPanel: NSObject {
    var onGesture: ((Bool) -> Void)?

    private let window: NSWindow
    private let body = SettingsBody()
    private let titleLabel = UtkaChrome.label("Настройки", size: 18, weight: .semibold)
    private let hints: [NSTextField]
    private let gestureTitle = UtkaChrome.label("Жест", size: 13, weight: .semibold)
    private let gestureSwitch = NSSwitch()
    private let gestureLabel = UtkaChrome.label("Включён", size: 13)
    private let languageTitle = UtkaChrome.label("Перевод", size: 13, weight: .semibold)
    private let languageLine = UtkaChrome.label("Проверь в настройках языка, скачаны ли английский и русский.", size: 12, color: UtkaChrome.dim)
    private let languageButton = NSButton()
    private let updateTitle = UtkaChrome.label("Обновления", size: 13, weight: .semibold)
    private let updateButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var checking = false
    private var applyingGesture = false

    override init() {
        hints = [
            "Кромка по центру сверху открывает островок на этом мониторе.",
            "Полка, буфер, заготовки и перевод — разделы слева.",
            "Снимок области — кнопка на верхней полосе.",
            "Ползунок ведёт громкость выхода «Утка звук».",
            "Escape прячет островок."
        ].map { UtkaChrome.label($0, size: 12, color: UtkaChrome.dim) }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Настройки"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        body.arrange = { [weak self] in self?.layoutContents() }
        window.contentView = body
        for hint in hints { body.addSubview(hint) }
        languageLine.maximumNumberOfLines = 2
        languageLine.lineBreakMode = .byWordWrapping
        languageLine.cell?.wraps = true
        gestureSwitch.target = self
        gestureSwitch.action = #selector(gestureMoved)
        mount(languageButton, title: "Открыть настройки языка", action: #selector(openLanguages))
        mount(updateButton, title: "Проверить обновления", action: #selector(checkUpdates))
        body.addSubview(titleLabel)
        body.addSubview(gestureTitle)
        body.addSubview(gestureSwitch)
        body.addSubview(gestureLabel)
        body.addSubview(languageTitle)
        body.addSubview(languageLine)
        body.addSubview(languageButton)
        body.addSubview(updateTitle)
        body.addSubview(updateButton)
        body.addSubview(updateLine)
    }

    /// Ставит окно по центру экрана островка и показывает текущий жест.
    func show(on screen: NSScreen?, gestureEnabled: Bool) {
        setGesture(gestureEnabled)
        let size = window.frame.size
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.setFrame(NSRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        ), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(body)
    }

    /// Синхронизирует тумблер с меню, не запуская повторное включение.
    func setGesture(_ on: Bool) {
        let state: NSControl.StateValue = on ? .on : .off
        guard gestureSwitch.state != state else { return }
        applyingGesture = true
        gestureSwitch.state = state
        applyingGesture = false
    }

    @objc private func gestureMoved() {
        guard !applyingGesture else { return }
        onGesture?(gestureSwitch.state == .on)
    }

    @objc private func openLanguages() {
        ShortcutTranslate.openLanguageSettings()
    }

    /// Сверяет номер сборки с последним выпуском. Скачивать нечего, пока выпусков нет.
    @objc private func checkUpdates() {
        guard !checking else { return }
        checking = true
        updateLine.stringValue = "Проверяю…"
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/utka-apps/utka/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.showRelease(data ?? Data(), status: code)
            }
        }.resume()
    }

    /// Кнопка с тем же гротеском, что и остальное окно.
    private func mount(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = UtkaChrome.font(13, weight: .medium)
        button.target = self
        button.action = action
        button.sizeToFit()
    }

    private func layoutContents() {
        let width = body.bounds.width
        let text = NSRect(x: 22, y: 0, width: max(120, width - 44), height: 0)
        var y: CGFloat = 40
        titleLabel.frame = NSRect(x: text.minX, y: y, width: text.width, height: 24)
        y += 34
        for hint in hints {
            hint.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
            y += 22
        }
        y += 10
        gestureTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 24
        gestureSwitch.frame = NSRect(x: text.minX, y: y, width: 38, height: 22)
        gestureLabel.frame = NSRect(x: text.minX + 48, y: y, width: text.width - 48, height: 22)
        y += 36
        languageTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 22
        languageLine.frame = NSRect(x: text.minX, y: y, width: text.width, height: 32)
        y += 38
        languageButton.frame = NSRect(x: text.minX, y: y, width: languageButton.frame.width + 8, height: 28)
        y += 40
        updateTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 24
        updateButton.frame = NSRect(x: text.minX, y: y, width: updateButton.frame.width + 8, height: 28)
        y += 34
        updateLine.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
    }

    private func showRelease(_ data: Data, status: Int) {
        if status == 401 || status == 403 || status == 404 {
            updateLine.stringValue = "Выпусков ещё нет"
            return
        }
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            updateLine.stringValue = "Не удалось проверить"
            return
        }
        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        if remote == current {
            updateLine.stringValue = "Это версия \(current)"
        } else {
            updateLine.stringValue = "Есть выпуск \(remote). Сейчас \(current)."
        }
    }
}

/// Фон окна настроек. Escape закрывает.
private final class SettingsBody: NSView {
    var arrange: () -> Void = {}

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        arrange()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        window?.close()
    }
}
