import AppKit

/// Окно настроек. Открывается кликом по утке на островке.
final class SettingsPanel: NSObject {
    private let window: NSWindow
    private let body = SettingsBody()
    private let titleLabel = UtkaChrome.label("Настройки", size: 18, weight: .semibold)
    private let hints: [NSTextField]
    private let languageTitle = UtkaChrome.label("Перевод", size: 13, weight: .semibold)
    private let englishName = UtkaChrome.label("Английский", size: 13)
    private let englishState = UtkaChrome.label("", size: 13, color: UtkaChrome.dim)
    private let russianName = UtkaChrome.label("Русский", size: 13)
    private let russianState = UtkaChrome.label("", size: 13, color: UtkaChrome.dim)
    private let languageButton = NSButton()
    private let languageNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let languageSettings = NSButton()
    private let updateTitle = UtkaChrome.label("Обновления", size: 13, weight: .semibold)
    private let updateButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var checking = false
    private var downloading = false

    override init() {
        hints = [
            "Кромка по центру сверху открывает островок на этом мониторе.",
            "Полка, буфер, заготовки и перевод — разделы слева.",
            "Снимок области — кнопка на верхней полосе.",
            "Ползунок ведёт громкость выхода «Утка звук».",
            "Escape прячет островок."
        ].map { UtkaChrome.label($0, size: 12, color: UtkaChrome.dim) }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
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
        englishState.alignment = .right
        russianState.alignment = .right
        languageNote.maximumNumberOfLines = 2
        languageNote.lineBreakMode = .byWordWrapping
        languageNote.cell?.wraps = true
        mount(languageButton, title: "Скачать английский и русский", action: #selector(downloadLanguages))
        mount(languageSettings, title: "Открыть настройки языка", action: #selector(openLanguages))
        mount(updateButton, title: "Проверить обновления", action: #selector(checkUpdates))
        body.addSubview(titleLabel)
        body.addSubview(languageTitle)
        body.addSubview(englishName)
        body.addSubview(englishState)
        body.addSubview(russianName)
        body.addSubview(russianState)
        body.addSubview(languageButton)
        body.addSubview(languageNote)
        body.addSubview(languageSettings)
        refreshLanguages()
        body.addSubview(updateTitle)
        body.addSubview(updateButton)
        body.addSubview(updateLine)
    }

    /// Ставит окно по центру экрана островка.
    func show(on screen: NSScreen?) {
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
        refreshLanguages()
    }

    /// Подписи «скачан» только по файлам. Кнопка скачивания — если какого-то пакета нет.
    private func refreshLanguages() {
        let packs = LanguagePacks.items()
        paint(englishState, ready: packs.contains { $0.title == "Английский" && $0.ready })
        paint(russianState, ready: packs.contains { $0.title == "Русский" && $0.ready })
        let missing = packs.contains { !$0.ready }
        languageButton.isHidden = !missing
        languageButton.isEnabled = !downloading
        if !missing {
            languageNote.stringValue = ""
        }
        languageSettings.isHidden = languageNote.stringValue.isEmpty || languageNote.stringValue == "Качаю…"
        body.needsLayout = true
    }

    /// «Скачан», только когда пакет уже лежит на диске.
    private func paint(_ label: NSTextField, ready: Bool) {
        label.stringValue = ready ? "скачан" : "нет"
        label.textColor = ready ? UtkaChrome.ink : UtkaChrome.dim
    }

    @objc private func downloadLanguages() {
        guard !downloading else { return }
        downloading = true
        languageNote.stringValue = "Качаю…"
        languageSettings.isHidden = true
        refreshLanguages()
        LanguagePacks.download { [weak self] error in
            guard let self else { return }
            self.downloading = false
            self.refreshLanguages()
            let ready = LanguagePacks.items().allSatisfy(\.ready)
            if ready {
                self.languageNote.stringValue = ""
                self.languageSettings.isHidden = true
                return
            }
            self.languageNote.stringValue = error ?? "На диске пакета нет"
            self.languageSettings.isHidden = false
            self.body.needsLayout = true
        }
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

    /// Строка языка: имя слева, «скачан» или «нет» справа.
    private func placePack(_ name: NSTextField, _ state: NSTextField, y: CGFloat, text: NSRect) -> CGFloat {
        let stateWidth: CGFloat = 88
        name.frame = NSRect(x: text.minX, y: y, width: text.width - stateWidth, height: 18)
        state.frame = NSRect(x: text.maxX - stateWidth, y: y, width: stateWidth, height: 18)
        return y + 22
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
        languageTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 24
        y = placePack(englishName, englishState, y: y, text: text)
        y = placePack(russianName, russianState, y: y, text: text)
        if !languageButton.isHidden {
            y += 6
            languageButton.frame = NSRect(x: text.minX, y: y, width: languageButton.frame.width + 8, height: 28)
            y += 34
        }
        if !languageNote.stringValue.isEmpty {
            languageNote.frame = NSRect(x: text.minX, y: y, width: text.width, height: 32)
            y += 36
        }
        if !languageSettings.isHidden {
            languageSettings.frame = NSRect(x: text.minX, y: y, width: languageSettings.frame.width + 8, height: 28)
            y += 36
        }
        y += 8
        updateTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 24
        updateButton.frame = NSRect(x: text.minX, y: y, width: updateButton.frame.width + 8, height: 28)
        y += 34
        updateLine.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        fitWindow(contentBottom: y + 16)
    }

    /// Держит верх окна на месте и убирает пустоту под последней строкой.
    private func fitWindow(contentBottom: CGFloat) {
        let height = contentBottom + 28
        let frame = window.frame
        guard abs(frame.height - height) > 1 else { return }
        let top = frame.maxY
        window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
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
