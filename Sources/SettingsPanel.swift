import AppKit

/// Звук и поиск на полосе. Включаются независимо и оба сразу.
enum IslandBar {
    private static let soundKey = "islandSound"
    private static let searchKey = "islandSearch"
    private static let legacyKey = "islandBar"

    static var sound: Bool {
        get { stored(soundKey) }
        set { UserDefaults.standard.set(newValue, forKey: soundKey) }
    }

    static var search: Bool {
        get { stored(searchKey) }
        set { UserDefaults.standard.set(newValue, forKey: searchKey) }
    }

    private static func stored(_ key: String) -> Bool {
        migrate()
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Старый режим «или звук, или поиск» раскладывается на два флажка.
    private static func migrate() {
        guard UserDefaults.standard.object(forKey: soundKey) == nil,
              UserDefaults.standard.object(forKey: searchKey) == nil else { return }
        let old = UserDefaults.standard.object(forKey: legacyKey) as? Int ?? 0
        UserDefaults.standard.set(old == 1, forKey: soundKey)
        UserDefaults.standard.set(old == 2, forKey: searchKey)
    }
}
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
    /// Меняет верхнюю полосу островка.
    var onIslandBar: (() -> Void)?

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
    private let soundLabel = UtkaChrome.label("Звук", size: 13, weight: .semibold)
    private let soundSwitch = NSSwitch()
    private let soundCaption = UtkaChrome.label(
        "Плагин «Утка звук» нужен, чтобы одним кликом перенести звук между мониторами и наушниками; на одном мониторе он не нужен.",
        size: 12,
        color: UtkaChrome.dim
    )
    private let soundInstall = NSButton()
    private let soundNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let soundReady = UtkaChrome.label("Плагин установлен", size: 13)
    private let soundCheck = installedMark()
    private let searchLabel = UtkaChrome.label("Поиск", size: 13, weight: .semibold)
    private let searchSwitch = NSSwitch()
    private let lookLabel = UtkaChrome.label("Режим", size: 13, weight: .semibold)
    private let lookMode = NSSegmentedControl()
    private let glassLabel = UtkaChrome.label("Стекло", size: 13, weight: .semibold)
    private let glassSlider = NSSlider()
    private let accentLabel = UtkaChrome.label("Цвет элементов", size: 13, weight: .semibold)
    private let accentWell = NSColorWell()
    private let strokeLabel = UtkaChrome.label("Обводка", size: 13, weight: .semibold)
    private let strokeSwitch = NSSwitch()
    private let strokeColorLabel = UtkaChrome.label("Цвет обводки", size: 13, weight: .semibold)
    private let strokeWell = NSColorWell()
    /// Стекло и вуаль окна, как у капли.
    private let chrome = SettingsChrome()
    /// Обводка по краю окна, если она включена.
    private let strokeOverlay = SettingsStroke()
    private let nativeReady = UtkaChrome.label("Языковой пакет установлен", size: 13)
    private let nativeCheck = installedMark()
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
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = IslandLook.appearance
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        body.arrange = { [weak self] in self?.layoutContents() }
        chrome.install(body: body, stroke: strokeOverlay)
        window.contentView = chrome
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
        soundCaption.maximumNumberOfLines = 4
        soundCaption.lineBreakMode = .byWordWrapping
        soundCaption.cell?.wraps = true
        soundNote.maximumNumberOfLines = 3
        soundNote.lineBreakMode = .byWordWrapping
        soundNote.cell?.wraps = true
        mount(soundInstall, title: "Установить плагин звука", action: #selector(installSoundPlugin))
        wire(soundSwitch, action: #selector(soundToggled))
        wire(searchSwitch, action: #selector(searchToggled))
        lookMode.segmentCount = 3
        lookMode.setLabel("Как в системе", forSegment: 0)
        lookMode.setLabel("Светлая", forSegment: 1)
        lookMode.setLabel("Тёмная", forSegment: 2)
        lookMode.trackingMode = .selectOne
        lookMode.segmentDistribution = .fillEqually
        lookMode.font = UtkaChrome.font(12, weight: .medium)
        lookMode.target = self
        lookMode.action = #selector(lookModeChanged)
        lookMode.selectedSegment = IslandLook.mode.rawValue
        glassSlider.minValue = 0
        glassSlider.maxValue = 1
        glassSlider.doubleValue = IslandLook.glass
        glassSlider.target = self
        glassSlider.action = #selector(glassChanged)
        accentWell.color = IslandLook.accent
        accentWell.isContinuous = true
        accentWell.target = self
        accentWell.action = #selector(accentChanged)
        wire(strokeSwitch, action: #selector(strokeToggled))
        strokeSwitch.state = IslandLook.strokeOn ? .on : .off
        strokeWell.color = IslandLook.strokeColor
        strokeWell.isContinuous = true
        strokeWell.target = self
        strokeWell.action = #selector(strokeColorChanged)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelColorChanged),
            name: NSColorPanel.colorDidChangeNotification,
            object: NSColorPanel.shared
        )
        refreshIslandSwitches()
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
        body.addSubview(soundLabel)
        body.addSubview(soundSwitch)
        body.addSubview(soundCaption)
        body.addSubview(soundInstall)
        body.addSubview(soundNote)
        body.addSubview(soundReady)
        body.addSubview(soundCheck)
        body.addSubview(searchLabel)
        body.addSubview(searchSwitch)
        body.addSubview(lookLabel)
        body.addSubview(lookMode)
        body.addSubview(glassLabel)
        body.addSubview(glassSlider)
        body.addSubview(accentLabel)
        body.addSubview(accentWell)
        body.addSubview(strokeLabel)
        body.addSubview(strokeSwitch)
        body.addSubview(strokeColorLabel)
        body.addSubview(strokeWell)
        body.addSubview(nativeReady)
        body.addSubview(nativeCheck)
        paintTabs()
        refreshNative()
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: IslandLook.changed, object: nil)
        paintChrome()
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
        refreshIslandSwitches()
        refreshNative()
        select(.island)
    }

    /// Вкладка без рамки. Белая, когда выбрана.
    private func makeTab(_ title: String, page: SettingsPage) -> NSButton {
        let button = NSButton()
        button.title = title
        button.tag = page.rawValue
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
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
                    .foregroundColor: on ? IslandLook.accent : UtkaChrome.dim
                ]
            )
            button.layer?.backgroundColor = (on ? IslandLook.accent.withAlphaComponent(0.22) : NSColor.clear).cgColor
            button.sizeToFit()
        }
    }

    /// Показывает контролы только текущей вкладки.
    private func applyPageVisibility() {
        let translate = page == .translate
        let pack = NativeTranslate.isInstalled
        nativeReady.isHidden = !translate || !pack
        nativeCheck.isHidden = !translate || !pack
        nativeTitle.isHidden = !translate || pack
        nativeState.isHidden = !translate || pack
        nativeNote.isHidden = !translate || pack
        nativeButton.isHidden = !translate || pack || NativeTranslate.isInstalled
        let updates = page == .updates
        versionLabel.isHidden = !updates
        updateButton.isHidden = !updates
        restoreButton.isHidden = !updates
        updateLine.isHidden = !updates
        installButton.isHidden = !updates || !canInstall
        let shot = page == .shot
        shotCleanupLabel.isHidden = !shot
        shotCleanup.isHidden = !shot
        let island = page == .island
        let plugged = SoundPlugin.isInstalled
        soundLabel.isHidden = !island
        soundSwitch.isHidden = !island
        soundCaption.isHidden = !island
        soundInstall.isHidden = !island || plugged
        soundNote.isHidden = !island || plugged || soundNote.stringValue.isEmpty
        soundReady.isHidden = !island || !plugged
        soundCheck.isHidden = !island || !plugged
        searchLabel.isHidden = !island
        searchSwitch.isHidden = !island
        lookLabel.isHidden = !island
        lookMode.isHidden = !island
        glassLabel.isHidden = !island
        glassSlider.isHidden = !island
        accentLabel.isHidden = !island
        accentWell.isHidden = !island
        strokeLabel.isHidden = !island
        strokeSwitch.isHidden = !island
        let stroke = island && IslandLook.strokeOn
        strokeColorLabel.isHidden = !stroke
        strokeWell.isHidden = !stroke
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

    /// Включает источники звука на полосе. Поиск не трогает.
    @objc private func soundToggled() {
        IslandBar.sound = soundSwitch.state == .on
        onIslandBar?()
    }

    /// Включает поле поиска на полосе. Звук не трогает.
    @objc private func searchToggled() {
        IslandBar.search = searchSwitch.state == .on
        onIslandBar?()
    }

    /// Ставит тумблеры по сохранённым флажкам. По умолчанию оба выключены.
    private func refreshIslandSwitches() {
        soundSwitch.state = IslandBar.sound ? .on : .off
        searchSwitch.state = IslandBar.search ? .on : .off
    }

    /// Просит плагин. Без релиза в системную папку ничего не пишет.
    @objc private func installSoundPlugin() {
        soundInstall.isEnabled = false
        soundNote.stringValue = ""
        SoundPlugin.install { [weak self] message in
            guard let self else { return }
            self.soundInstall.isEnabled = !SoundPlugin.isInstalled
            self.soundNote.stringValue = message ?? ""
            self.applyPageVisibility()
            self.body.needsLayout = true
        }
    }

    /// Тумблер с тем же гротеском, что и окно.
    private func wire(_ toggle: NSSwitch, action: Selector) {
        toggle.target = self
        toggle.action = action
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
            y = layoutIsland(text: text, y: y)
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

    /// Звук и поиск. Включён может быть только один.
    private func layoutIsland(text: NSRect, y: CGFloat) -> CGFloat {
        var y = layoutToggle(soundLabel, soundSwitch, text: text, y: y) + 8
        let captionHeight = measuredHeight(soundCaption.stringValue, width: text.width, font: soundCaption.font, limit: 72)
        soundCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: captionHeight)
        y += captionHeight + 10
        if SoundPlugin.isInstalled {
            y = layoutInstalled(soundReady, soundCheck, text: text, y: y)
        } else {
            soundInstall.isEnabled = true
            soundInstall.frame = NSRect(x: text.minX, y: y, width: soundInstall.frame.width + 8, height: 28)
            y += 34
            if !soundNote.stringValue.isEmpty {
                let noteHeight = measuredHeight(soundNote.stringValue, width: text.width, font: soundNote.font, limit: 48)
                soundNote.frame = NSRect(x: text.minX, y: y, width: text.width, height: noteHeight)
                y += noteHeight + 8
            }
        }
        y += 8
        y = layoutToggle(searchLabel, searchSwitch, text: text, y: y) + 18
        return layoutLook(text: text, y: y)
    }

    /// Режим, стекло и один цвет выбранного.
    private func layoutLook(text: NSRect, y: CGFloat) -> CGFloat {
        var y = y
        lookLabel.frame = NSRect(x: text.minX, y: y, width: text.width, height: 18)
        y += 22
        lookMode.frame = NSRect(x: text.minX, y: y, width: text.width, height: 24)
        y += 34
        let sliderWidth = min(180, text.width * 0.46)
        glassLabel.frame = NSRect(x: text.minX, y: y + 5, width: text.width - sliderWidth - 12, height: 18)
        glassSlider.frame = NSRect(x: text.maxX - sliderWidth, y: y, width: sliderWidth, height: 28)
        y += 40
        y = layoutColor(accentLabel, accentWell, text: text, y: y) + 12
        y = layoutToggle(strokeLabel, strokeSwitch, text: text, y: y)
        guard IslandLook.strokeOn else { return y + 8 }
        return layoutColor(strokeColorLabel, strokeWell, text: text, y: y + 12) + 8
    }

    /// Подпись слева, лунка цвета справа. Высота с запасом, чтобы кружок не срезало.
    private func layoutColor(_ label: NSTextField, _ well: NSColorWell, text: NSRect, y: CGFloat) -> CGFloat {
        well.frame = NSRect(x: text.maxX - 44, y: y, width: 44, height: 28)
        label.frame = NSRect(x: text.minX, y: y + 5, width: text.width - 56, height: 18)
        return y + 28
    }

    @objc private func lookModeChanged() {
        guard let next = IslandLookMode(rawValue: lookMode.selectedSegment) else { return }
        IslandLook.mode = next
    }

    @objc private func glassChanged() {
        IslandLook.glass = glassSlider.doubleValue
    }

    @objc private func accentChanged() {
        IslandLook.accent = accentWell.color
    }

    @objc private func strokeToggled() {
        IslandLook.strokeOn = strokeSwitch.state == .on
    }

    @objc private func strokeColorChanged() {
        IslandLook.strokeColor = strokeWell.color
    }

    /// Пока крутят цвет в панели, островок и это окно меняются сразу.
    @objc private func panelColorChanged() {
        let color = NSColorPanel.shared.color
        if accentWell.isActive {
            IslandLook.accent = color
        } else if strokeWell.isActive {
            IslandLook.strokeColor = color
        }
    }

    /// Окно настроек тем же режимом, что островок.
    @objc private func lookChanged() {
        paintChrome()
        body.needsLayout = true
    }

    /// Чернила, стекло и обводка — тем же видом, что островок.
    private func paintChrome() {
        window.appearance = IslandLook.appearance
        window.backgroundColor = .clear
        chrome.apply()
        strokeOverlay.needsDisplay = true
        let inkLabels = [titleLabel, soundLabel, searchLabel, soundReady, nativeReady, nativeTitle, versionLabel, shotCleanupLabel, lookLabel, glassLabel, accentLabel, strokeLabel, strokeColorLabel]
        inkLabels.forEach { $0.textColor = UtkaChrome.ink }
        let dimLabels = [soundCaption, soundNote, nativeNote, nativeState, updateLine]
        dimLabels.forEach { $0.textColor = UtkaChrome.dim }
        lookMode.selectedSegment = IslandLook.mode.rawValue
        glassSlider.doubleValue = IslandLook.glass
        if !accentWell.isActive { accentWell.color = IslandLook.accent }
        strokeSwitch.state = IslandLook.strokeOn ? .on : .off
        if !strokeWell.isActive { strokeWell.color = IslandLook.strokeColor }
        paintTabs()
    }

    /// Надпись «установлен» и зелёная галка.
    private func layoutInstalled(_ label: NSTextField, _ mark: NSImageView, text: NSRect, y: CGFloat) -> CGFloat {
        mark.frame = NSRect(x: text.minX, y: y, width: 18, height: 18)
        label.frame = NSRect(x: text.minX + 24, y: y, width: text.width - 24, height: 18)
        return y + 22
    }

    /// Зелёная галка у уже стоящего пакета или плагина.
    private static func installedMark() -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Установлено")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        view.contentTintColor = .systemGreen
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    /// Подпись слева, тумблер справа. Возвращает низ ряда.
    private func layoutToggle(_ label: NSTextField, _ toggle: NSSwitch, text: NSRect, y: CGFloat) -> CGFloat {
        let switchSize = toggle.fittingSize
        let row = max(22, switchSize.height)
        label.frame = NSRect(x: text.minX, y: y + (row - 18) / 2, width: max(40, text.width - switchSize.width - 12), height: 18)
        toggle.frame = NSRect(
            x: text.maxX - switchSize.width,
            y: y + (row - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        return y + row
    }

    /// Высота многострочной подписи.
    private func measuredHeight(_ string: String, width: CGFloat, font: NSFont?, limit: CGFloat) -> CGFloat {
        let measured = (string as NSString).boundingRect(
            with: NSSize(width: width, height: limit),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font as Any]
        )
        return min(limit, max(16, ceil(measured.height)))
    }

    /// Блок своего движка перевода.
    private func layoutTranslate(text: NSRect, y: CGFloat) -> CGFloat {
        var y = y
        if NativeTranslate.isInstalled {
            return layoutInstalled(nativeReady, nativeCheck, text: text, y: y)
        }
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
        let height = contentBottom + 40
        let frame = window.frame
        guard abs(frame.height - height) > 1 else { return }
        let top = frame.maxY
        window.setFrame(NSRect(x: frame.minX, y: top - height, width: frame.width, height: height), display: true)
    }

}

/// Матовое стекло окна. Плотность вуали та же, что у капли.
private final class SettingsChrome: NSVisualEffectView {
    private let veil = NSView()
    private weak var body: NSView?
    private weak var stroke: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        blendingMode = .behindWindow
        state = .active
        material = .hudWindow
        veil.wantsLayer = true
        addSubview(veil)
    }

    required init?(coder: NSCoder) { nil }

    /// Кладёт содержимое и обводку поверх стекла.
    func install(body: NSView, stroke: NSView) {
        self.body = body
        self.stroke = stroke
        addSubview(body)
        addSubview(stroke)
    }

    override func layout() {
        super.layout()
        veil.frame = bounds
        body?.frame = bounds
        stroke?.frame = bounds
        if let stroke, subviews.last !== stroke {
            addSubview(stroke, positioned: .above, relativeTo: nil)
        }
    }

    /// Подтягивает материал и плотность под текущий вид.
    func apply() {
        material = IslandLook.dark ? .hudWindow : .menu
        appearance = IslandLook.appearance
        isHidden = false
        veil.layer?.backgroundColor = IslandLook.veil.cgColor
    }
}

/// Обводка по краю окна. Клики проходят к контролам.
private final class SettingsStroke: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard IslandLook.strokeOn else { return }
        let width: CGFloat = 2.5
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: width / 2 + 1, dy: width / 2 + 1),
            xRadius: 12,
            yRadius: 12
        )
        path.lineWidth = width
        IslandLook.strokeColor.setStroke()
        path.stroke()
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
