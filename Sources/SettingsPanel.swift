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
    private let updateTitle = UtkaChrome.label("Обновления", size: 13, weight: .semibold)
    private let updateButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let installButton = NSButton()
    private var checking = false
    private var installing = false
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
        updateLine.maximumNumberOfLines = 8
        updateLine.lineBreakMode = .byWordWrapping
        updateLine.cell?.wraps = true
        mount(updateButton, title: "Проверить обновления", action: #selector(checkUpdates))
        mount(installButton, title: "Установить", action: #selector(installUpdate))
        installButton.isHidden = true
        body.addSubview(titleLabel)
        body.addSubview(languageTitle)
        body.addSubview(englishName)
        body.addSubview(englishState)
        body.addSubview(russianName)
        body.addSubview(russianState)
        body.addSubview(languageButton)
        body.addSubview(languageNote)
        refreshLanguages()
        body.addSubview(updateTitle)
        body.addSubview(updateButton)
        body.addSubview(updateLine)
        body.addSubview(installButton)
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
        body.needsLayout = true
    }

    /// «Скачан», только когда пакет уже лежит на диске.
    private func paint(_ label: NSTextField, ready: Bool) {
        label.stringValue = ready ? "скачан" : "нет"
        label.textColor = ready ? UtkaChrome.ink : UtkaChrome.dim
    }

    /// Сначала пробует скачать сама, тихо. Если не вышло — сама же открывает
    /// нужную страницу настроек, без второй кнопки и лишнего клика.
    @objc private func downloadLanguages() {
        guard !downloading else { return }
        downloading = true
        languageNote.stringValue = "Качаю…"
        refreshLanguages()
        LanguagePacks.download { [weak self] error in
            guard let self else { return }
            self.downloading = false
            self.refreshLanguages()
            let ready = LanguagePacks.items().allSatisfy(\.ready)
            if ready {
                self.languageNote.stringValue = ""
                return
            }
            self.languageNote.stringValue = "Открываю настройки языка — довершите загрузку там"
            self.body.needsLayout = true
            ShortcutTranslate.openLanguageSettings()
        }
    }

    /// Сверяет сборку с общим main и показывает, что именно готово.
    @objc private func checkUpdates() {
        guard !checking, !installing else { return }
        checking = true
        installButton.isHidden = true
        updateButton.isEnabled = false
        updateLine.stringValue = "Проверяю общий main…"
        body.needsLayout = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = AppUpdate.look()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.updateButton.isEnabled = true
                self.installButton.isHidden = !report.canInstall
                self.updateLine.stringValue = report.text
                self.body.needsLayout = true
            }
        }
    }

    /// Забирает общий main, собирает утку и открывает её заново.
    @objc private func installUpdate() {
        guard !installing, !installButton.isHidden else { return }
        installing = true
        installButton.isEnabled = false
        updateButton.isEnabled = false
        updateLine.stringValue = "Забираю общий main…"
        body.needsLayout = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = AppUpdate.prepareInstall()
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.installing = false
                    self.installButton.isEnabled = true
                    self.updateButton.isEnabled = true
                    self.updateLine.stringValue = error
                    self.body.needsLayout = true
                    return
                }
                guard AppUpdate.startRebuild() else {
                    self.installing = false
                    self.installButton.isEnabled = true
                    self.updateButton.isEnabled = true
                    self.updateLine.stringValue = "Не удалось начать сборку"
                    self.body.needsLayout = true
                    return
                }
                self.updateLine.stringValue = "Собираю и открою заново"
                NSApp.terminate(nil)
            }
        }
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
        y += 8
        updateTitle.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
        y += 24
        updateButton.frame = NSRect(x: text.minX, y: y, width: updateButton.frame.width + 8, height: 28)
        y += 34
        if !updateLine.stringValue.isEmpty {
            let lines = updateLine.stringValue.split(separator: "\n", omittingEmptySubsequences: false).count
            let height = CGFloat(min(max(lines, 1), 8)) * 16
            updateLine.frame = NSRect(x: text.minX, y: y, width: text.width, height: height)
            y += height + 8
        }
        if !installButton.isHidden {
            installButton.frame = NSRect(x: text.minX, y: y, width: installButton.frame.width + 8, height: 28)
            y += 36
        }
        fitWindow(contentBottom: y + 8)
    }

    /// Держит верх окна на месте и убирает пустоту под последней строкой.
    private func fitWindow(contentBottom: CGFloat) {
        let height = contentBottom + 28
        let frame = window.frame
        guard abs(frame.height - height) > 1 else { return }
        let top = frame.maxY
        window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
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
