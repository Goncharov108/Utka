import AppKit

/// Окно настроек. Открывается кликом по утке на островке.
final class SettingsPanel: NSObject {
    private let window: NSWindow
    private let body = SettingsBody()
    private let titleLabel = UtkaChrome.label("Настройки", size: 18, weight: .semibold)
    private let hints: [NSTextField]
    private let nativeTitle = UtkaChrome.label("Перевод", size: 13, weight: .semibold)
    private let nativeState = UtkaChrome.label("", size: 13, color: UtkaChrome.dim)
    private let nativeButton = NSButton()
    private let nativeNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var nativeDownloading = false
    private let updateTitle = UtkaChrome.label("Обновления", size: 13, weight: .semibold)
    private let versionLabel = UtkaChrome.label("", size: 13)
    private let updateButton = NSButton()
    private let restoreButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let installButton = NSButton()
    private var checking = false
    private var installing = false
    private var restoring = false

    override init() {
        hints = [
            "Кромка по центру сверху открывает островок на этом мониторе.",
            "Клик по утке на островке открывает вот это окно.",
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
        nativeState.alignment = .right
        nativeNote.maximumNumberOfLines = 2
        nativeNote.lineBreakMode = .byWordWrapping
        nativeNote.cell?.wraps = true
        mount(nativeButton, title: "Скачать (≈150 МБ)", action: #selector(downloadNative))
        updateLine.maximumNumberOfLines = 8
        updateLine.lineBreakMode = .byWordWrapping
        updateLine.cell?.wraps = true
        versionLabel.stringValue = Self.visibleVersion()
        versionLabel.alignment = .right
        mount(updateButton, title: "Проверить обновления", action: #selector(checkUpdates))
        mount(restoreButton, title: "Вернуть предыдущую", action: #selector(restorePrevious))
        mount(installButton, title: "Установить", action: #selector(installUpdate))
        installButton.isHidden = true
        body.addSubview(titleLabel)
        body.addSubview(nativeTitle)
        body.addSubview(nativeState)
        body.addSubview(nativeButton)
        body.addSubview(nativeNote)
        refreshNative()
        body.addSubview(updateTitle)
        body.addSubview(versionLabel)
        body.addSubview(updateButton)
        body.addSubview(restoreButton)
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
        refreshNative()
    }

    /// Свой офлайн-движок перевода: utka-apps/utka-translate. Единственный
    /// способ перевода в Утке — ни Apple, ни какой-либо сторонний сервис,
    /// ни открытие системных настроек здесь больше не задействованы.
    private func refreshNative() {
        let ready = NativeTranslate.isInstalled
        nativeState.stringValue = ready ? "скачан" : "нет"
        nativeState.textColor = ready ? UtkaChrome.ink : UtkaChrome.dim
        nativeButton.isHidden = ready
        nativeButton.isEnabled = !nativeDownloading
        if ready {
            nativeNote.stringValue = ""
        }
        body.needsLayout = true
    }

    @objc private func downloadNative() {
        guard !nativeDownloading else { return }
        nativeDownloading = true
        nativeNote.stringValue = "Качаю…"
        refreshNative()
        NativeTranslate.download { [weak self] error in
            guard let self else { return }
            self.nativeDownloading = false
            self.refreshNative()
            if let error {
                self.nativeNote.stringValue = error
                self.body.needsLayout = true
            }
        }
    }

    /// Номер из собранного приложения, с буквой v.
    private static func visibleVersion() -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return ""
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.hasPrefix("v") ? text : "v\(text)"
    }

    /// Сверяет сборку с общим main и показывает, что именно готово.
    @objc private func checkUpdates() {
        guard !checking, !installing, !restoring else { return }
        checking = true
        installButton.isHidden = true
        updateButton.isEnabled = false
        restoreButton.isEnabled = false
        updateLine.stringValue = "Проверяю общий main…"
        body.needsLayout = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = AppUpdate.look()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.updateButton.isEnabled = true
                self.restoreButton.isEnabled = true
                self.installButton.isHidden = !report.canInstall
                self.updateLine.stringValue = report.text
                self.body.needsLayout = true
            }
        }
    }

    /// Забирает общий main, собирает утку и открывает её заново.
    @objc private func installUpdate() {
        guard !installing, !restoring, !installButton.isHidden else { return }
        installing = true
        installButton.isEnabled = false
        updateButton.isEnabled = false
        restoreButton.isEnabled = false
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
                    self.restoreButton.isEnabled = true
                    self.updateLine.stringValue = error
                    self.body.needsLayout = true
                    return
                }
                guard AppUpdate.startRebuild() else {
                    self.installing = false
                    self.installButton.isEnabled = true
                    self.updateButton.isEnabled = true
                    self.restoreButton.isEnabled = true
                    self.updateLine.stringValue = "Не удалось начать сборку"
                    self.body.needsLayout = true
                    return
                }
                self.updateLine.stringValue = "Собираю и открою заново"
                NSApp.terminate(nil)
            }
        }
    }

    /// Ставит предыдущую утку на место текущей. Без копии только пишет, что возвращать нечего.
    @objc private func restorePrevious() {
        guard !restoring, !installing, !checking else { return }
        restoring = true
        restoreButton.isEnabled = false
        updateButton.isEnabled = false
        installButton.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = AppUpdate.startRestore()
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.restoring = false
                    self.restoreButton.isEnabled = true
                    self.updateButton.isEnabled = true
                    self.installButton.isEnabled = !self.installButton.isHidden
                    self.updateLine.stringValue = error
                    self.body.needsLayout = true
                    return
                }
                NSApp.terminate(nil)
            }
        }
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
        nativeTitle.frame = NSRect(x: text.minX, y: y, width: text.width - 88, height: 16)
        nativeState.frame = NSRect(x: text.maxX - 88, y: y, width: 88, height: 16)
        y += 22
        if !nativeButton.isHidden {
            nativeButton.frame = NSRect(x: text.minX, y: y, width: nativeButton.frame.width + 8, height: 28)
            y += 34
        }
        if !nativeNote.stringValue.isEmpty {
            nativeNote.frame = NSRect(x: text.minX, y: y, width: text.width, height: 32)
            y += 36
        }
        y += 8
        updateTitle.frame = NSRect(x: text.minX, y: y, width: text.width - 88, height: 16)
        versionLabel.frame = NSRect(x: text.maxX - 88, y: y, width: 88, height: 16)
        y += 24
        let updateWidth = updateButton.frame.width + 8
        let restoreWidth = restoreButton.frame.width + 8
        updateButton.frame = NSRect(x: text.minX, y: y, width: updateWidth, height: 28)
        let restoreX = text.minX + updateWidth + 8
        if restoreX + restoreWidth <= text.maxX {
            restoreButton.frame = NSRect(x: restoreX, y: y, width: restoreWidth, height: 28)
            y += 34
        } else {
            y += 34
            restoreButton.frame = NSRect(x: text.minX, y: y, width: restoreWidth, height: 28)
            y += 34
        }
        if !updateLine.stringValue.isEmpty {
            let measured = (updateLine.stringValue as NSString).boundingRect(
                with: NSSize(width: text.width, height: 128),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: updateLine.font as Any]
            )
            let height = min(128, max(16, ceil(measured.height)))
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
