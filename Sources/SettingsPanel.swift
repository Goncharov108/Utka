import AppKit

/// Страница окна настроек. На экране видна одна.
private enum SettingsPage: Int {
    case island
    case translate
    case updates
    case shot
}

/// Окно настроек. Открывается кликом по утке на островке.
final class SettingsPanel: NSObject {
    /// Сообщает полке, снимать ли свой снимок после переноса.
    var onDeleteShotAfterUse: ((Bool) -> Void)?

    private let window: NSWindow
    private let body = SettingsBody()
    private let titleLabel = UtkaChrome.label("Настройки", size: 18, weight: .semibold)
    private var tabButtons: [NSButton] = []
    private var page: SettingsPage = .island
    private let nativeTitle = UtkaChrome.label("Перевод", size: 13, weight: .semibold)
    private let nativeState = UtkaChrome.label("", size: 13, color: UtkaChrome.dim)
    private let nativeButton = NSButton()
    private let nativeNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var nativeDownloading = false
    private let versionLabel = UtkaChrome.label("", size: 13)
    private let updateButton = NSButton()
    private let restoreButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let installButton = NSButton()
    private let shotCleanupLabel = UtkaChrome.label("Удалять скрин из полки после использования", size: 13)
    private let shotCleanup = NSSwitch()
    private var canInstall = false
    private var checking = false
    private var installing = false
    private var restoring = false

    override init() {
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
        nativeState.alignment = .right
        nativeNote.maximumNumberOfLines = 2
        nativeNote.lineBreakMode = .byWordWrapping
        nativeNote.cell?.wraps = true
        mount(nativeButton, title: "Скачать (≈150 МБ)", action: #selector(downloadNative))
        updateLine.maximumNumberOfLines = 8
        updateLine.lineBreakMode = .byWordWrapping
        updateLine.cell?.wraps = true
        versionLabel.stringValue = Self.visibleVersion()
        mount(updateButton, title: "Проверить обновления", action: #selector(checkUpdates))
        mount(restoreButton, title: "Вернуть предыдущую", action: #selector(restorePrevious))
        mount(installButton, title: "Установить", action: #selector(installUpdate))
        shotCleanupLabel.maximumNumberOfLines = 2
        shotCleanupLabel.lineBreakMode = .byWordWrapping
        shotCleanupLabel.cell?.wraps = true
        shotCleanup.target = self
        shotCleanup.action = #selector(shotCleanupToggled)
        shotCleanup.state = ShelfModel.deleteShotAfterUse ? .on : .off
        body.addSubview(titleLabel)
        tabButtons = [
            makeTab("Островок", page: .island),
            makeTab("Скрин", page: .shot),
            makeTab("Перевод", page: .translate),
            makeTab("Обновления", page: .updates)
        ]
        body.addSubview(nativeTitle)
        body.addSubview(nativeState)
        body.addSubview(nativeButton)
        body.addSubview(nativeNote)
        body.addSubview(versionLabel)
        body.addSubview(updateButton)
        body.addSubview(restoreButton)
        body.addSubview(updateLine)
        body.addSubview(installButton)
        body.addSubview(shotCleanupLabel)
        body.addSubview(shotCleanup)
        paintTabs()
        refreshNative()
    }

    /// Ставит окно по центру экрана и каждый раз открывает «Островок».
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
        shotCleanup.state = ShelfModel.deleteShotAfterUse ? .on : .off
        refreshNative()
        select(.island)
    }

    /// Вкладка без рамки. Белая, когда выбрана.
    private func makeTab(_ title: String, page: SettingsPage) -> NSButton {
        let button = NSButton()
        button.title = title
        button.tag = page.rawValue
        button.isBordered = false
        button.target = self
        button.action = #selector(tabClicked(_:))
        body.addSubview(button)
        return button
    }

    /// Красит выбранную вкладку белым, остальные приглушает.
    private func paintTabs() {
        let titles = ["Островок", "Перевод", "Обновления", "Скрин"]
        for button in tabButtons {
            let on = button.tag == page.rawValue
            let title = titles[button.tag]
            button.title = title
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: UtkaChrome.font(13, weight: on ? .semibold : .medium),
                    .foregroundColor: on ? UtkaChrome.ink : UtkaChrome.dim
                ]
            )
            button.sizeToFit()
        }
    }

    /// Показывает контролы только текущей вкладки.
    private func applyPageVisibility() {
        let translate = page == .translate
        nativeTitle.isHidden = !translate
        nativeState.isHidden = !translate
        nativeNote.isHidden = !translate
        nativeButton.isHidden = !translate || NativeTranslate.isInstalled
        let updates = page == .updates
        versionLabel.isHidden = !updates
        updateButton.isHidden = !updates
        restoreButton.isHidden = !updates
        updateLine.isHidden = !updates
        installButton.isHidden = !updates || !canInstall
        let shot = page == .shot
        shotCleanupLabel.isHidden = !shot
        shotCleanup.isHidden = !shot
    }

    /// Переключает вкладку и поджимает окно под неё.
    private func select(_ next: SettingsPage) {
        page = next
        paintTabs()
        applyPageVisibility()
        body.needsLayout = true
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let next = SettingsPage(rawValue: sender.tag) else { return }
        select(next)
    }

    /// Запоминает, снимать ли свой снимок с полки после переноса.
    @objc private func shotCleanupToggled() {
        onDeleteShotAfterUse?(shotCleanup.state == .on)
    }

    /// Свой офлайн-движок перевода: utka-apps/utka-translate. Единственный
    /// способ перевода в Утке — ни Apple, ни какой-либо сторонний сервис,
    /// ни открытие системных настроек здесь больше не задействованы.
    private func refreshNative() {
        let ready = NativeTranslate.isInstalled
        nativeState.stringValue = ready ? "скачан" : "нет"
        nativeState.textColor = ready ? UtkaChrome.ink : UtkaChrome.dim
        nativeButton.isEnabled = !nativeDownloading
        if ready {
            nativeNote.stringValue = ""
        }
        applyPageVisibility()
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
        canInstall = false
        updateButton.isEnabled = false
        restoreButton.isEnabled = false
        updateLine.stringValue = "Проверяю общий main…"
        applyPageVisibility()
        body.needsLayout = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = AppUpdate.look()
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.updateButton.isEnabled = true
                self.restoreButton.isEnabled = true
                self.canInstall = report.canInstall
                self.updateLine.stringValue = report.text
                self.applyPageVisibility()
                self.body.needsLayout = true
            }
        }
    }

    /// Забирает общий main, собирает утку и открывает её заново.
    @objc private func installUpdate() {
        guard !installing, !restoring, canInstall else { return }
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
                    self.installButton.isEnabled = self.canInstall
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
        applyPageVisibility()
        let width = body.bounds.width
        let text = NSRect(x: 22, y: 0, width: max(120, width - 44), height: 0)
        var y: CGFloat = 40
        titleLabel.frame = NSRect(x: text.minX, y: y, width: text.width, height: 24)
        y += 34
        y = layoutTabs(x: text.minX, y: y) + 16
        switch page {
        case .island:
            break
        case .translate:
            y = layoutTranslate(text: text, y: y)
        case .updates:
            y = layoutUpdates(text: text, y: y)
        case .shot:
            y = layoutShot(text: text, y: y)
        }
        fitWindow(contentBottom: y + 8)
    }

    /// Ряд вкладок. Возвращает его низ.
    private func layoutTabs(x: CGFloat, y: CGFloat) -> CGFloat {
        var cursor = x
        for button in tabButtons {
            let width = max(button.fittingSize.width, 24)
            button.frame = NSRect(x: cursor, y: y, width: width, height: 22)
            cursor += width + 18
        }
        return y + 22
    }

    /// Блок своего движка перевода.
    private func layoutTranslate(text: NSRect, y: CGFloat) -> CGFloat {
        var y = y
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
        return y
    }

    /// Номер, проверка, возврат и установка.
    private func layoutUpdates(text: NSRect, y: CGFloat) -> CGFloat {
        var y = y
        versionLabel.frame = NSRect(x: text.minX, y: y, width: text.width, height: 16)
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
        return y
    }

    /// Подпись слева, боковой тумблер справа.
    private func layoutShot(text: NSRect, y: CGFloat) -> CGFloat {
        let switchSize = shotCleanup.fittingSize
        let gap: CGFloat = 12
        let labelWidth = max(80, text.width - switchSize.width - gap)
        let measured = (shotCleanupLabel.stringValue as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: 44),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: shotCleanupLabel.font as Any]
        )
        let labelHeight = max(18, ceil(measured.height))
        let row = max(labelHeight, switchSize.height)
        shotCleanupLabel.frame = NSRect(x: text.minX, y: y + (row - labelHeight) / 2, width: labelWidth, height: labelHeight)
        shotCleanup.frame = NSRect(
            x: text.maxX - switchSize.width,
            y: y + (row - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        return y + row
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
