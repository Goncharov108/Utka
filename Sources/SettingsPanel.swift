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
private enum SettingsPage: Int, CaseIterable {
    case theme, sections, sound, search, shot, clipboard, calendar, translate, updates

    var title: String {
        switch self {
        case .theme: return "Островок"
        case .sections: return "Разделы"
        case .sound: return "Звук"
        case .search: return "Поиск"
        case .shot: return "Полка"
        case .clipboard: return "Буфер"
        case .calendar: return "Календарь"
        case .translate: return "Перевод"
        case .updates: return "Обновления"
        }
    }

    /// Пункты, которые выезжают из «Островка». Сама тема к ним не относится.
    var underIsland: Bool {
        self == .sections || self == .sound || self == .search
    }
}

/// Окно настроек. Открывается кликом по утке на островке.
final class SettingsPanel: NSObject {
    /// Сообщает полке, снимать ли свой снимок после переноса.
    var onDeleteShotAfterUse: ((Bool) -> Void)?
    /// Что делать с файлом снимка: оставить, в корзину или навсегда.
    var onShotDisposal: ((ShotDisposal) -> Void)?
    /// Меняет верхнюю полосу островка.
    var onIslandBar: (() -> Void)?
    /// Настройки буфера поменяли — история применяет их сразу.
    var onClipboardPrefs: (() -> Void)?

    private let window: NSWindow
    private let body = SettingsBody()
    private let titleLabel = UtkaChrome.label("Настройки", size: 18, weight: .semibold)
    private let railLine = NSView()
    private let chevron = SidebarGlyph()
    private let chevronMark: NSImage = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Подменю островка")?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? NSImage()
    private let nest = FlippedView()
    private let pill = NSView()
    private var sideButtons: [MenuRow] = []
    private var pillRect = NSRect.zero
    private var pillTarget = NSRect.zero
    private var motionTimer: Timer?
    private var sectionLines: [SectionLine] = []
    private var libraryLines: [LibraryOfferLine] = []
    private let libraryButton = NSButton()
    private let libraryBack = NSButton()
    private let libraryEmpty = UtkaChrome.label("Пока пусто", size: 13, color: UtkaChrome.dim)
    private var showingLibrary = false
    private var dragLine: SectionLine?
    private var settlingLine: SectionLine?
    private var dragY: CGFloat = 0
    private var sectionOrigin: CGFloat = 0
    private var sectionHome: [ObjectIdentifier: CGFloat] = [:]
    private var sectionShown: [ObjectIdentifier: CGFloat] = [:]
    private var lift: CGFloat = 0
    private var liftTarget: CGFloat = 0
    private var page: SettingsPage = .theme
    /// 0 — подменю спрятано, 1 — раскрыто. Между ними кадры таймера.
    private var reveal: CGFloat = 0
    private var revealFrom: CGFloat = 0
    private var revealTarget: CGFloat = 0
    private var revealBegan = Date()
    private var layingOut = false
    private let nativeTitle = UtkaChrome.label("Перевод", size: 13, weight: .semibold)
    private let nativeState = UtkaChrome.label("", size: 13, color: UtkaChrome.dim)
    private let nativeButton = NSButton()
    private let nativeNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var nativeDownloading = false
    private let versionLabel = UtkaChrome.label("", size: 13)
    private let updateButton = NSButton()
    private let restoreButton = NSButton()
    private let updateLine = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let updateCheck = installedMark()
    private var updateIsCurrent = false
    private let installButton = NSButton()
    private let shotCleanupLabel = UtkaChrome.label("Удалять скрин из полки\nпосле использования", size: 13)
    private let shotCleanup = NSSwitch()
    private let shotDisposalLabel = UtkaChrome.label("Удалять скрин из полки", size: 13)
    private let shotDisposal = NSSegmentedControl()
    /// Настройки буфера. Страница «Буфер» пишет их сразу.
    private let clipPrefs = ClipboardPrefs()
    /// Главный выключатель истории буфера.
    private let clipRemember = SwitchRow("Запоминать скопированное")
    /// Пропускать то, что менеджеры паролей пометили скрытым.
    private let clipSecrets = SwitchRow("Не сохранять пароли")
    /// Что считается паролем — под тумблером.
    private let clipSecretsCaption = caption("Пароли, которые менеджер паролей пометил как скрытые")
    /// Срок записей. Число и единица — под ним, пока он включён.
    private let clipExpire = SwitchRow("Удалять записи старше")
    /// Сколько единиц срока, от 1 до 999.
    private let clipAge = NSTextField()
    /// Единица срока: минут, часов, дней.
    private let clipAgeUnit = NSSegmentedControl()
    /// Чистить историю при первом запуске после перезагрузки.
    private let clipReboot = SwitchRow("Чистить после перезагрузки Мака")
    /// Окно «Убрать / Оставить» перед «Очистить».
    private let clipConfirm = SwitchRow("Спрашивать перед очисткой")
    /// Крякер — напоминатель заметок календаря. Страница «Календарь».
    private let quackSwitch = SwitchRow("Крякер")
    private let quackCaption = caption("Крякает, когда у заметки календаря наступило время, пока её не откроешь.")
    private let quackRepeat = SwitchRow("Повторять кряк")
    private let quackThrough = UtkaChrome.label("через", size: 13, weight: .semibold)
    private let quackAge = NSTextField()
    private let quackAgeUnit = NSSegmentedControl()
    private let soundLabel = UtkaChrome.label("Звук", size: 13, weight: .semibold)
    private let soundSwitch = NSSwitch()
    private let soundCaption = caption(
        "Плагин «Утка звук» даёт менять громкость на мониторе и в наушниках, подключённых к монитору. Без него macOS громкость там не регулирует. Переключать выходы можно и без плагина."
    )
    private let soundInstall = NSButton()
    private let soundNote = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private let soundReady = UtkaChrome.label("Плагин установлен", size: 13)
    private let soundCheck = installedMark()
    private let searchLabel = UtkaChrome.label("Поиск", size: 13, weight: .semibold)
    private let searchSwitch = NSSwitch()
    private let searchCaption = caption(
        "Поле поиска на полосе островка. Находит программы, файлы и папки, считает примеры (12*7), переводит единицы (5 км в м) и показывает слово из словаря Мака. Стрелки выбирают строку, Return открывает её, а готовый ответ копирует. Внизу всегда есть поиск в интернете."
    )
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
    private let translateCaption = caption(
        "Раздел «Переводчик» на островке: слева английский, справа русский. Пишешь в любое окно — через полсекунды перевод появляется в соседнем. Языковой пакет скачивается один раз и дальше переводит прямо на Маке, без интернета: текст никуда не уходит."
    )
    private let nativeCheck = installedMark()
    private var canInstall = false
    private var checking = false
    private var installing = false
    private var restoring = false

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
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
        allowWrap(shotCleanupLabel)
        shotCleanup.target = self
        shotCleanup.action = #selector(shotCleanupToggled)
        shotCleanup.state = ShelfModel.deleteShotAfterUse ? .on : .off
        segments(shotDisposal, ShotDisposal.allCases.map(\.title), action: #selector(shotDisposalChanged))
        refreshShotDisposal()
        clipRows.forEach { wire($0.toggle, action: #selector(clipboardToggled(_:))) }
        clipAge.font = UtkaChrome.font(13)
        clipAge.alignment = .center
        clipAge.bezelStyle = .roundedBezel
        clipAge.target = self
        clipAge.action = #selector(clipAgeCommitted)
        clipAge.cell?.sendsActionOnEndEditing = true
        segments(clipAgeUnit, ClipboardPrefs.Unit.allCases.map(\.title), action: #selector(clipUnitChanged))
        refreshClipboard()
        wire(quackSwitch.toggle, action: #selector(quackerToggled))
        wire(quackRepeat.toggle, action: #selector(quackRepeatToggled))
        quackAge.font = UtkaChrome.font(13)
        quackAge.alignment = .center
        quackAge.bezelStyle = .roundedBezel
        quackAge.target = self
        quackAge.action = #selector(quackAgeCommitted)
        quackAge.cell?.sendsActionOnEndEditing = true
        segments(quackAgeUnit, QuackerPrefs.Unit.allCases.map(\.title), action: #selector(quackUnitChanged))
        refreshQuacker()
        soundNote.maximumNumberOfLines = 3
        soundNote.lineBreakMode = .byWordWrapping
        soundNote.cell?.wraps = true
        mount(soundInstall, title: "Установить плагин звука", action: #selector(installSoundPlugin))
        wire(soundSwitch, action: #selector(soundToggled))
        wire(searchSwitch, action: #selector(searchToggled))
        segments(lookMode, ["Как в системе", "Светлая", "Тёмная"], action: #selector(lookModeChanged))
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
        railLine.wantsLayer = true
        nest.wantsLayer = true
        nest.layer?.masksToBounds = true
        nest.layer?.backgroundColor = NSColor.clear.cgColor
        quietLayer(nest)
        titleLabel.autoresizingMask = []
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        quietLayer(pill)
        chevron.image = chevronMark
        chevron.imageScaling = .scaleProportionallyDown
        chevron.contentTintColor = UtkaChrome.dim
        body.addSubview(pill)
        body.addSubview(titleLabel)
        body.addSubview(railLine)
        body.addSubview(nest)
        body.addSubview(chevron)
        sideButtons = [makeRow("Островок", tag: -1) { [weak self] in self?.islandClicked() }]
            + SettingsPage.allCases.filter { $0 != .theme }.map { pageRow($0) }
        for row in sideButtons where row.rowTag >= 0 && SettingsPage(rawValue: row.rowTag)?.underIsland == true {
            row.removeFromSuperview()
            nest.addSubview(row)
        }
        rebuildSectionLines()
        mount(libraryButton, title: "Библиотека", action: #selector(libraryClicked))
        libraryBack.isBordered = false
        libraryBack.bezelStyle = .shadowlessSquare
        libraryBack.imagePosition = .imageOnly
        libraryBack.imageScaling = .scaleProportionallyDown
        libraryBack.image = utkaSymbol("chevron.left", point: 13, label: "К разделам")
        libraryBack.toolTip = "К разделам"
        libraryBack.target = self
        libraryBack.action = #selector(libraryBackClicked)
        libraryEmpty.alignment = .center
        body.addSubview(libraryButton)
        body.addSubview(libraryBack)
        body.addSubview(libraryEmpty)
        refreshSectionToggles()
        body.addSubview(nativeTitle)
        body.addSubview(nativeState)
        body.addSubview(nativeButton)
        body.addSubview(nativeNote)
        body.addSubview(versionLabel)
        body.addSubview(updateButton)
        body.addSubview(restoreButton)
        body.addSubview(updateLine)
        body.addSubview(updateCheck)
        body.addSubview(installButton)
        body.addSubview(shotCleanupLabel)
        body.addSubview(shotCleanup)
        body.addSubview(shotDisposalLabel)
        body.addSubview(shotDisposal)
        (clipViews + [clipAge, clipAgeUnit]).forEach { body.addSubview($0) }
        ([quackSwitch.label, quackSwitch.toggle, quackCaption, quackRepeat.label, quackRepeat.toggle, quackThrough, quackAge, quackAgeUnit] as [NSView])
            .forEach { body.addSubview($0) }
        body.addSubview(soundLabel)
        body.addSubview(soundSwitch)
        body.addSubview(soundCaption)
        body.addSubview(soundInstall)
        body.addSubview(soundNote)
        body.addSubview(soundReady)
        body.addSubview(soundCheck)
        body.addSubview(searchLabel)
        body.addSubview(searchSwitch)
        body.addSubview(searchCaption)
        body.addSubview(translateCaption)
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
        paintSidebar()
        refreshNative()
        NotificationCenter.default.addObserver(self, selector: #selector(lookChanged), name: IslandLook.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sectionsChanged), name: IslandSection.orderChanged, object: nil)
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
        refreshShotDisposal()
        refreshIslandSwitches()
        refreshClipboard()
        refreshQuacker()
        refreshNative()
        reveal = 0
        revealFrom = 0
        revealTarget = 0
        select(.theme, animated: false)
    }

    /// Строка меню: текст с одним левым краем, без системной кнопки.
    private func makeRow(_ title: String, tag: Int, click: @escaping () -> Void) -> MenuRow {
        let row = MenuRow(title: title, rowTag: tag)
        row.onClick = click
        body.addSubview(row)
        return row
    }

    /// Пункт меню, который открывает свою страницу.
    private func pageRow(_ page: SettingsPage) -> MenuRow {
        makeRow(page.title, tag: page.rawValue) { [weak self] in self?.pick(page) }
    }

    private func pick(_ next: SettingsPage) {
        if next == .sections {
            showLibrary(false)
        }
        select(next, animated: true)
    }

    /// Красит подписи. Подсветка живёт отдельно и перетекает сама.
    private func paintSidebar() {
        let childOn = page.underIsland
        for row in sideButtons {
            let group = row.rowTag < 0
            let on = group ? page == .theme : row.rowTag == page.rawValue
            let marked = on || (group && childOn)
            row.titleLabel.font = UtkaChrome.font(13, weight: marked ? .semibold : .medium)
            row.titleLabel.textColor = marked ? IslandLook.accent : UtkaChrome.dim
        }
        chevron.contentTintColor = UtkaChrome.dim
        railLine.layer?.backgroundColor = UtkaChrome.dim.withAlphaComponent(0.28).cgColor
        pill.layer?.backgroundColor = IslandLook.accent.withAlphaComponent(0.22).cgColor
        sectionLines.forEach { $0.applyLook() }
        libraryLines.forEach { $0.applyLook() }
        libraryEmpty.textColor = UtkaChrome.dim
        libraryBack.contentTintColor = UtkaChrome.ink
    }

    /// Показывает контролы только текущей вкладки.
    private func applyPageVisibility() {
        let translate = page == .translate
        let pack = NativeTranslate.isInstalled
        translateCaption.isHidden = !translate
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
        updateCheck.isHidden = !updates || !updateIsCurrent || updateLine.stringValue.isEmpty
        installButton.isHidden = !updates || !canInstall
        let shot = page == .shot
        shotCleanupLabel.isHidden = !shot
        shotCleanup.isHidden = !shot
        let disposal = shot && shotCleanup.state == .on
        shotDisposalLabel.isHidden = !disposal
        shotDisposal.isHidden = !disposal
        let clipboard = page == .clipboard
        clipViews.forEach { $0.isHidden = !clipboard }
        let age = clipboard && clipExpire.toggle.state == .on
        clipAge.isHidden = !age
        clipAgeUnit.isHidden = !age
        let calendarPage = page == .calendar
        quackSwitch.label.isHidden = !calendarPage
        quackSwitch.toggle.isHidden = !calendarPage
        quackCaption.isHidden = !calendarPage
        let quackOn = calendarPage && quackSwitch.toggle.state == .on
        quackRepeat.label.isHidden = !quackOn
        quackRepeat.toggle.isHidden = !quackOn
        let repeatOn = quackOn && quackRepeat.toggle.state == .on
        quackThrough.isHidden = !repeatOn
        quackAge.isHidden = !repeatOn
        quackAgeUnit.isHidden = !repeatOn
        let sound = page == .sound
        let plugged = SoundPlugin.isInstalled
        soundLabel.isHidden = !sound
        soundSwitch.isHidden = !sound
        soundCaption.isHidden = !sound
        soundInstall.isHidden = !sound || plugged
        soundNote.isHidden = !sound || plugged || soundNote.stringValue.isEmpty
        soundReady.isHidden = !sound || !plugged
        soundCheck.isHidden = !sound || !plugged
        let search = page == .search
        searchLabel.isHidden = !search
        searchSwitch.isHidden = !search
        searchCaption.isHidden = !search
        let sections = page == .sections
        let libraryOpen = sections && showingLibrary
        sectionLines.forEach { $0.isHidden = !sections || showingLibrary }
        libraryLines.forEach { $0.isHidden = !libraryOpen }
        libraryEmpty.isHidden = !libraryOpen || !libraryLines.isEmpty
        libraryButton.isHidden = !sections || showingLibrary
        libraryBack.isHidden = !libraryOpen
        let theme = page == .theme
        lookLabel.isHidden = !theme
        lookMode.isHidden = !theme
        glassLabel.isHidden = !theme
        glassSlider.isHidden = !theme
        accentLabel.isHidden = !theme
        accentWell.isHidden = !theme
        strokeLabel.isHidden = !theme
        strokeSwitch.isHidden = !theme
        let stroke = theme && IslandLook.strokeOn
        strokeColorLabel.isHidden = !stroke
        strokeWell.isHidden = !stroke
    }

    /// Переключает пункт меню. Подменю островка при этом доезжает само.
    private func select(_ next: SettingsPage, animated: Bool) {
        page = next
        paintSidebar()
        applyPageVisibility()
        if animated && next.underIsland && reveal < 1 {
            animateReveal(to: 1)
        } else {
            body.needsLayout = true
        }
    }

    /// «Островок» показывает тему. Повторный щелчок по теме складывает подменю.
    @objc private func islandClicked() {
        if reveal < 0.98 {
            page = .theme
            applyPageVisibility()
            paintSidebar()
            animateReveal(to: 1)
            return
        }
        if page != .theme {
            page = .theme
            applyPageVisibility()
            paintSidebar()
            body.needsLayout = true
            return
        }
        paintSidebar()
        animateReveal(to: 0)
    }

    /// Кадры сами: у фонового приложения системный аниматор не тикает и меню дёргается.
    private func animateReveal(to target: CGFloat) {
        revealFrom = reveal
        revealTarget = target
        revealBegan = Date()
        kickMotion()
    }

    /// Подменю и пятно выбора едут одним тактом.
    private func kickMotion() {
        guard motionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            self?.stepMotion(timer)
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    private func stepMotion(_ timer: Timer) {
        var moving = false
        if abs(reveal - revealTarget) > 0.004 {
            let duration = 0.36
            let t = min(1, Date().timeIntervalSince(revealBegan) / duration)
            let eased = 1 - pow(1 - t, 3)
            reveal = revealFrom + (revealTarget - revealFrom) * CGFloat(eased)
            if t >= 1 { reveal = revealTarget }
            moving = abs(reveal - revealTarget) > 0.004
        }
        if !pillTarget.isEmpty {
            let dx = pillTarget.origin.x - pillRect.origin.x
            let dy = pillTarget.origin.y - pillRect.origin.y
            let dw = pillTarget.width - pillRect.width
            let dh = pillTarget.height - pillRect.height
            if abs(dx) > 0.4 || abs(dy) > 0.4 || abs(dw) > 0.4 || abs(dh) > 0.4 {
                pillRect.origin.x += dx * 0.2
                pillRect.origin.y += dy * 0.2
                pillRect.size.width += dw * 0.2
                pillRect.size.height += dh * 0.2
                moving = true
            } else {
                pillRect = pillTarget
            }
        }
        if abs(lift - liftTarget) > 0.01 {
            lift += (liftTarget - lift) * 0.2
            moving = true
        } else {
            lift = liftTarget
        }
        for line in sectionLines {
            let id = ObjectIdentifier(line)
            guard line !== dragLine, let home = sectionHome[id], var shown = sectionShown[id] else { continue }
            let dy = home - shown
            if abs(dy) > 0.4 {
                shown += dy * 0.2
                sectionShown[id] = shown
                moving = true
            } else {
                sectionShown[id] = home
            }
        }
        if !moving { settlingLine = nil }
        body.needsLayout = true
        guard !moving else { return }
        timer.invalidate()
        motionTimer = nil
    }

    /// Запоминает, снимать ли свой снимок с полки после переноса.
    @objc private func shotCleanupToggled() {
        onDeleteShotAfterUse?(shotCleanup.state == .on)
        applyPageVisibility()
        body.needsLayout = true
    }

    /// В корзину или стереть навсегда.
    @objc private func shotDisposalChanged() {
        let options = ShotDisposal.allCases
        guard options.indices.contains(shotDisposal.selectedSegment) else { return }
        onShotDisposal?(options[shotDisposal.selectedSegment])
    }

    /// Ставит сегмент по сохранённому выбору.
    private func refreshShotDisposal() {
        shotDisposal.selectedSegment = ShotDisposal.allCases.firstIndex(of: ShelfModel.shotDisposal) ?? 0
    }

    /// Тумблеры страницы «Буфер» сверху вниз.
    private var clipRows: [SwitchRow] { [clipRemember, clipSecrets, clipExpire, clipReboot, clipConfirm] }

    /// Всё на странице «Буфер», кроме числа и единицы срока: те видны, только пока срок включён.
    private var clipViews: [NSView] { clipRows.flatMap { [$0.label, $0.toggle] } + [clipSecretsCaption] }

    /// Тумблер страницы «Буфер»: пишет свою настройку, история применяет её сразу.
    @objc private func clipboardToggled(_ sender: NSSwitch) {
        let on = sender.state == .on
        switch sender {
        case clipRemember.toggle: clipPrefs.remember = on
        case clipSecrets.toggle: clipPrefs.skipSecrets = on
        case clipExpire.toggle: clipPrefs.expires = on
        case clipReboot.toggle: clipPrefs.clearOnReboot = on
        case clipConfirm.toggle: clipPrefs.confirmClear = on
        default: return
        }
        applyPageVisibility()
        body.needsLayout = true
        onClipboardPrefs?()
    }

    /// Число срока — по Return или уходу из поля. Пустое, ноль и больше 999 не сохраняются: в поле возвращается прежнее.
    @objc private func clipAgeCommitted() {
        let typed = Int(clipAge.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        if ClipboardPrefs.ageRange.contains(typed), typed != clipPrefs.ageCount {
            clipPrefs.ageCount = typed
            onClipboardPrefs?()
        }
        clipAge.stringValue = String(clipPrefs.ageCount)
    }

    /// Единица срока. Записи старше нового срока уходят сразу.
    @objc private func clipUnitChanged() {
        guard let unit = ClipboardPrefs.Unit(rawValue: clipAgeUnit.selectedSegment) else { return }
        clipPrefs.ageUnit = unit
        onClipboardPrefs?()
    }

    /// Ставит страницу «Буфер» по сохранённым настройкам.
    private func refreshClipboard() {
        clipRemember.toggle.state = clipPrefs.remember ? .on : .off
        clipSecrets.toggle.state = clipPrefs.skipSecrets ? .on : .off
        clipExpire.toggle.state = clipPrefs.expires ? .on : .off
        clipReboot.toggle.state = clipPrefs.clearOnReboot ? .on : .off
        clipConfirm.toggle.state = clipPrefs.confirmClear ? .on : .off
        clipAge.stringValue = String(clipPrefs.ageCount)
        clipAgeUnit.selectedSegment = clipPrefs.ageUnit.rawValue
    }

    /// Тумблер крякера: пишет сразу, ReminderEngine подхватывает.
    @objc private func quackerToggled() {
        QuackerPrefs.enabled = quackSwitch.toggle.state == .on
        applyPageVisibility()
        body.needsLayout = true
    }

    /// Повтор кряка: при выключении интервал прячется, ReminderEngine больше не тикает.
    @objc private func quackRepeatToggled() {
        QuackerPrefs.repeats = quackRepeat.toggle.state == .on
        applyPageVisibility()
        body.needsLayout = true
    }

    /// Число интервала кряка. Пустое и ноль не сохраняются: в поле возвращается прежнее.
    @objc private func quackAgeCommitted() {
        let typed = Int(quackAge.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        if QuackerPrefs.countRange.contains(typed), typed != QuackerPrefs.intervalCount {
            QuackerPrefs.intervalCount = typed
        }
        quackAge.stringValue = String(QuackerPrefs.intervalCount)
    }

    /// Единица интервала кряка.
    @objc private func quackUnitChanged() {
        guard let unit = QuackerPrefs.Unit(rawValue: quackAgeUnit.selectedSegment) else { return }
        QuackerPrefs.intervalUnit = unit
    }

    /// Ставит страницу «Календарь» по сохранённым настройкам.
    private func refreshQuacker() {
        quackSwitch.toggle.state = QuackerPrefs.enabled ? .on : .off
        quackRepeat.toggle.state = QuackerPrefs.repeats ? .on : .off
        quackAge.stringValue = String(QuackerPrefs.intervalCount)
        quackAgeUnit.selectedSegment = QuackerPrefs.intervalUnit.rawValue
    }

    /// Включает источники звука на полосе и саму петлю «Утка звук». Поиск не трогает.
    @objc private func soundToggled() {
        let on = soundSwitch.state == .on
        IslandBar.sound = on
        AudioOutput.shared.setSoundEnabled(on)
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

    /// Выбор одного из вариантов тем же гротеском, что и окно.
    private func segments(_ control: NSSegmentedControl, _ labels: [String], action: Selector) {
        control.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            control.setLabel(label, forSegment: index)
        }
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.font = UtkaChrome.font(12, weight: .medium)
        control.target = self
        control.action = action
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

    /// Сверяет сборку с main и показывает, что именно готово.
    @objc private func checkUpdates() {
        guard !checking, !installing, !restoring else { return }
        checking = true
        canInstall = false
        updateIsCurrent = false
        updateButton.isEnabled = false
        restoreButton.isEnabled = false
        updateLine.textColor = UtkaChrome.dim
        updateLine.stringValue = "Проверяю main…"
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
                self.updateIsCurrent = report.isUpToDate
                self.updateLine.stringValue = report.text
                self.updateLine.textColor = report.isUpToDate ? UtkaChrome.ink : UtkaChrome.dim
                self.applyPageVisibility()
                self.body.needsLayout = true
            }
        }
    }

    /// Открывает окно установки. Сборка идёт там, пока утка жива.
    @objc private func installUpdate() {
        guard !installing, !restoring, canInstall else { return }
        installing = true
        installButton.isEnabled = false
        updateButton.isEnabled = false
        restoreButton.isEnabled = false
        InstallWindow.present(over: window) { [weak self] in
            guard let self else { return }
            self.installing = false
            self.installButton.isEnabled = self.canInstall
            self.updateButton.isEnabled = true
            self.restoreButton.isEnabled = true
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

    /// Ширина по подписи. Текущий кадр не копится: иначе кнопка растёт каждый проход.
    private func buttonWidth(_ button: NSButton) -> CGFloat {
        ceil(button.fittingSize.width) + 8
    }

    private func layoutContents() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        applyPageVisibility()
        let width = body.bounds.width
        let rail: CGFloat = 168
        let pad: CGFloat = 20
        let chromeTop: CGFloat = 40
        let titleFont = titleLabel.font ?? UtkaChrome.font(18, weight: .semibold)
        let titleHeight = ceil(titleFont.ascender - titleFont.descender)
        titleLabel.frame = NSRect(x: 24, y: chromeTop, width: 132, height: titleHeight)
        let sideTop: CGFloat = chromeTop + 36
        let text = NSRect(x: rail + 24, y: 0, width: max(160, width - rail - 24 - pad), height: 0)
        let sideX: CGFloat = 12
        let sideW = rail - 20
        let above = layoutSidebar(x: sideX, y: sideTop, width: sideW)
        var y = sideTop
        switch page {
        case .theme:
            y = layoutLook(text: text, y: y)
        case .sections:
            y = layoutSections(text: text, y: y)
        case .sound:
            y = layoutSound(text: text, y: y)
        case .search:
            y = layoutSearch(text: text, y: y)
        case .translate:
            y = layoutTranslate(text: text, y: y)
        case .updates:
            y = layoutUpdates(text: text, y: y)
        case .shot:
            y = layoutShot(text: text, y: y)
        case .clipboard:
            y = layoutClipboard(text: text, y: y)
        case .calendar:
            y = layoutCalendar(text: text, y: y)
        }
        let sideBottom = pinUpdates(x: sideX, above: above, width: sideW, pageBottom: y)
        pourPill()
        let column = max(sideBottom, y)
        place(railLine, NSRect(x: rail, y: sideTop, width: 1, height: max(24, column - sideTop)))
        fitWindow(contentBottom: column + 8)
    }

    /// Левое меню. Тексты с одного края, подсветка перетекает к выбранной строке.
    private func layoutSidebar(x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let row: CGFloat = 34
        let gap: CGFloat = 2
        guard let island = sideButtons.first(where: { $0.rowTag < 0 }) else { return y }
        let children = sideButtons.filter { $0.rowTag >= 0 && SettingsPage(rawValue: $0.rowTag)?.underIsland == true }
        let rest = sideButtons.filter {
            $0.rowTag >= 0
                && $0.rowTag != SettingsPage.updates.rawValue
                && SettingsPage(rawValue: $0.rowTag)?.underIsland != true
        }
        island.textInset = 12
        place(island, NSRect(x: x, y: y, width: width, height: row))
        place(chevron, NSRect(x: x + width - 26, y: y + (row - 14) / 2, width: 14, height: 14))
        body.addSubview(chevron, positioned: .above, relativeTo: nil)
        turnChevron()
        var cursor = y + row + gap
        let full = CGFloat(children.count) * (row + gap)
        nest.frame = NSRect(x: x, y: cursor, width: width, height: max(0, full * reveal))
        var inner: CGFloat = 0
        for button in children {
            button.textInset = 26
            button.isHidden = reveal < 0.04
            button.alphaValue = reveal
            button.frame = NSRect(x: 0, y: inner, width: width, height: row)
            inner += row + gap
        }
        cursor += full * reveal
        for button in rest {
            button.textInset = 12
            place(button, NSRect(x: x, y: cursor, width: width, height: row))
            cursor += row + gap
        }
        return cursor
    }

    /// «Обновления» всегда у нижнего края окна, остальные пункты остаются сверху.
    private func pinUpdates(x: CGFloat, above: CGFloat, width: CGFloat, pageBottom: CGFloat) -> CGFloat {
        guard let updates = sideButtons.first(where: { $0.rowTag == SettingsPage.updates.rawValue }) else {
            return above
        }
        let row: CGFloat = 34
        let bottomPad: CGFloat = 18
        let minFloor: CGFloat = 300 - 28
        let floor = max(minFloor, above + row + bottomPad, pageBottom + bottomPad)
        let y = max(above + 8, floor - bottomPad - row)
        updates.textInset = 12
        place(updates, NSRect(x: x, y: y, width: width, height: row))
        return y + row
    }

    /// Стрелка остаётся справа в строке. Поворот слоя уносил её влево: якорь вида в нуле.
    private func turnChevron() {
        let angle = (1 - reveal) * (.pi / 2)
        guard abs(angle) > 0.001 else {
            chevron.image = chevronMark
            return
        }
        let size = chevronMark.size
        let turned = NSImage(size: size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byRadians: angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            self.chevronMark.draw(in: rect)
            return true
        }
        turned.isTemplate = true
        chevron.image = turned
    }

    /// Цель подсветки — выбранная строка. Пока едет, пятно тянется в сторону цели.
    private func pourPill() {
        guard let row = selectedRow() else { return }
        let target = row.convert(row.bounds, to: body).insetBy(dx: 6, dy: 3)
        if pillRect.isEmpty {
            pillRect = target
            pillTarget = target
        } else {
            pillTarget = target
        }
        let dy = pillTarget.midY - pillRect.midY
        let stretch = min(42, abs(dy) * 0.9)
        var drawn = pillRect
        if dy > 0.8 {
            drawn.size.height += stretch
        } else if dy < -0.8 {
            drawn.origin.y -= stretch
            drawn.size.height += stretch
        }
        pill.frame = drawn
        pill.layer?.cornerRadius = min(12, drawn.height / 2)
        if hypot(pillRect.midX - pillTarget.midX, pillRect.midY - pillTarget.midY) > 0.6 {
            kickMotion()
        }
    }

    private func selectedRow() -> MenuRow? {
        if page == .theme { return sideButtons.first { $0.rowTag < 0 } }
        return sideButtons.first { $0.rowTag == page.rawValue }
    }

    /// Строка раздела, которую можно перетащить. Порядок пишется и на островок.
    private func makeSectionLine(_ slot: SectionSlot) -> SectionLine {
        let line = SectionLine(slot: slot)
        line.onDrag = { [weak self, weak line] y in
            guard let self, let line else { return }
            self.dragLine = line
            self.settlingLine = nil
            self.dragY = y
            self.liftTarget = 1
            self.reorderDragged()
            self.body.addSubview(line, positioned: .above, relativeTo: nil)
            self.kickMotion()
            self.body.needsLayout = true
        }
        line.onDrop = { [weak self, weak line] in
            guard let self else { return }
            if self.dragLine === line {
                self.settlingLine = line
                self.dragLine = nil
                self.liftTarget = 0
                self.kickMotion()
            }
            self.body.needsLayout = true
        }
        line.onToggle = { [weak self] on in
            SectionBoard.setShown(slot.id, on)
            self?.refreshSectionToggles()
        }
        if slot.core == nil {
            line.onRemove = { [weak self] in
                SectionBoard.remove(slot.id)
                self?.rebuildSectionLines()
                self?.body.needsLayout = true
            }
        }
        return line
    }

    /// Тумблеры по записи. Последний включённый не даёт себя выключить и снять.
    private func refreshSectionToggles() {
        let alone = SectionBoard.visible.count <= 1
        for line in sectionLines {
            let on = SectionBoard.isShown(line.slot.id)
            let lastOn = on && alone
            line.setShown(on, enabled: !lastOn, canRemove: SectionBoard.canRemove(line.slot.id))
        }
    }

    /// Пока строку тащат, она меняется местами с той, чью середину пересекла.
    private func reorderDragged() {
        guard dragLine != nil else { return }
        let pitch: CGFloat = 48
        let target = min(max(0, Int(((dragY - sectionOrigin) / pitch).rounded())), sectionLines.count - 1)
        guard let from = sectionLines.firstIndex(where: { $0 === dragLine }), from != target else { return }
        let line = sectionLines.remove(at: from)
        sectionLines.insert(line, at: target)
        SectionBoard.order = sectionLines.map(\.slot)
    }

    /// Список поставленных разделов заново. Во время перетаскивания строки не выбрасывает.
    private func rebuildSectionLines() {
        guard dragLine == nil else { return }
        sectionLines.forEach { $0.removeFromSuperview() }
        sectionShown.removeAll()
        sectionHome.removeAll()
        sectionLines = SectionBoard.order.map { makeSectionLine($0) }
        sectionLines.forEach { body.addSubview($0) }
        refreshSectionToggles()
        applyPageVisibility()
    }

    /// Непоставленные карточки каталога. Пустой каталог оставляет одну строку «Пока пусто».
    private func rebuildLibraryLines() {
        libraryLines.forEach { $0.removeFromSuperview() }
        libraryLines = SectionBoard.offers.map { card in
            let line = LibraryOfferLine(card: card)
            line.onInstall = { [weak self] in
                SectionBoard.install(card.id)
                self?.rebuildLibraryLines()
                self?.body.needsLayout = true
            }
            body.addSubview(line)
            return line
        }
        applyPageVisibility()
    }

    /// Библиотека или список разделов. Каталог читается заново при каждом входе.
    private func showLibrary(_ on: Bool) {
        showingLibrary = on
        SectionBoard.reload()
        if on {
            rebuildLibraryLines()
        } else {
            rebuildSectionLines()
        }
        applyPageVisibility()
        body.needsLayout = true
    }

    @objc private func libraryClicked() {
        showLibrary(true)
    }

    /// Стрелка вверху библиотеки возвращает к списку разделов.
    @objc private func libraryBackClicked() {
        showLibrary(false)
    }

    /// Полоса и список подтягиваются, когда каталог или включение изменились снаружи.
    @objc private func sectionsChanged() {
        guard page == .sections, dragLine == nil else { return }
        if showingLibrary {
            rebuildLibraryLines()
        } else {
            let ids = SectionBoard.order.map(\.id)
            if ids != sectionLines.map(\.slot.id) {
                rebuildSectionLines()
            } else {
                refreshSectionToggles()
            }
        }
        body.needsLayout = true
    }

    /// Поставленные разделы и кнопка библиотеки под ними. В библиотеке — карточки, которые ещё не стоят.
    private func layoutSections(text: NSRect, y: CGFloat) -> CGFloat {
        if showingLibrary { return layoutLibrary(text: text, y: y) }
        sectionOrigin = y
        let row: CGFloat = 40
        let gap: CGFloat = 8
        let pitch = row + gap
        let limit = y + CGFloat(max(0, sectionLines.count - 1)) * pitch
        let traveling = dragLine != nil || settlingLine != nil
        var homes: [ObjectIdentifier: CGFloat] = [:]
        for (index, line) in sectionLines.enumerated() {
            let id = ObjectIdentifier(line)
            let home = y + CGFloat(index) * pitch
            homes[id] = home
            let shown: CGFloat
            if line === dragLine {
                shown = min(max(dragY, y), limit)
            } else if traveling, let current = sectionShown[id] {
                shown = current
            } else {
                shown = home
            }
            sectionShown[id] = shown
            let raised = line === dragLine || line === settlingLine
            let extra = raised ? 2 * lift : 0
            line.frame = NSRect(
                x: text.minX - extra,
                y: shown - extra,
                width: text.width + extra * 2,
                height: row + extra * 2
            )
            line.setLift(raised ? lift : 0)
        }
        sectionHome = homes
        if let raised = dragLine ?? settlingLine {
            body.addSubview(raised, positioned: .above, relativeTo: nil)
        }
        if traveling || abs(lift - liftTarget) > 0.01 {
            kickMotion()
        }
        let rowsBottom = y + CGFloat(sectionLines.count) * pitch
        return placeLibraryButton(text: text, y: rowsBottom)
    }

    /// Карточки каталога под стрелкой. Пустой каталог — одна строка.
    private func layoutLibrary(text: NSRect, y: CGFloat) -> CGFloat {
        libraryBack.frame = NSRect(x: text.minX - 6, y: y, width: 28, height: 22)
        let row: CGFloat = 40
        let gap: CGFloat = 8
        var cursor = y + 30
        if libraryLines.isEmpty {
            libraryEmpty.frame = NSRect(x: text.minX, y: cursor, width: text.width, height: 22)
            cursor += 30
        } else {
            for (index, line) in libraryLines.enumerated() {
                line.frame = NSRect(
                    x: text.minX,
                    y: cursor + CGFloat(index) * (row + gap),
                    width: text.width,
                    height: row
                )
            }
            cursor += CGFloat(libraryLines.count) * (row + gap)
        }
        return cursor
    }

    /// Кнопка под списком. В библиотеке она возвращает к разделам.
    private func placeLibraryButton(text: NSRect, y: CGFloat) -> CGFloat {
        let width = buttonWidth(libraryButton)
        libraryButton.frame = NSRect(x: text.minX, y: y + 4, width: width, height: 28)
        return y + 40
    }

    /// Тумблер поиска и под ним, что поиск умеет.
    private func layoutSearch(text: NSRect, y: CGFloat) -> CGFloat {
        let y = layoutToggle(searchLabel, searchSwitch, text: text, y: y) + 8
        let height = fieldHeight(searchCaption, width: text.width)
        searchCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: height)
        return y + height + 8
    }

    /// Приглушённая подпись под пунктом настроек. Переносится на сколько угодно строк.
    private static func caption(_ text: String) -> NSTextField {
        let field = UtkaChrome.label(text, size: 12, color: UtkaChrome.dim)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        return field
    }

    /// Высота подписи так, как её переносит само поле. Голый текст меряется короче, и последняя строка срезается.
    private func fieldHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
        field.preferredMaxLayoutWidth = width
        let bounds = NSRect(x: 0, y: 0, width: width, height: 10_000)
        let size = field.cell?.cellSize(forBounds: bounds) ?? .zero
        return max(16, ceil(size.height))
    }

    /// Звук на полосе и плагин.
    private func layoutSound(text: NSRect, y: CGFloat) -> CGFloat {
        var y = layoutToggle(soundLabel, soundSwitch, text: text, y: y) + 8
        let captionHeight = fieldHeight(soundCaption, width: text.width)
        soundCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: captionHeight)
        y += captionHeight + 10
        if SoundPlugin.isInstalled {
            y = layoutInstalled(soundReady, soundCheck, text: text, y: y)
        } else {
            soundInstall.isEnabled = true
            soundInstall.frame = NSRect(x: text.minX, y: y, width: buttonWidth(soundInstall), height: 28)
            y += 34
            if !soundNote.stringValue.isEmpty {
                let noteHeight = measuredHeight(soundNote.stringValue, width: text.width, font: soundNote.font, limit: 48)
                soundNote.frame = NSRect(x: text.minX, y: y, width: text.width, height: noteHeight)
                y += noteHeight + 8
            }
        }
        return y + 8
    }

    /// Слой не догоняет кадр своим аниматором: у фоновой утки он дёргается.
    private func quietLayer(_ view: NSView) {
        let still = StillLayer()
        view.layer?.actions = [
            "bounds": still,
            "position": still,
            "cornerRadius": still,
            "backgroundColor": still,
            "transform": still,
            "opacity": still
        ]
    }

    /// Кадр без системного аниматора: тот в фоновом приложении не тикает.
    private func place(_ view: NSView, _ frame: NSRect) {
        view.frame = frame
        view.alphaValue = 1
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
        let inkLabels = [titleLabel, soundLabel, searchLabel, soundReady, nativeReady, nativeTitle, versionLabel, shotCleanupLabel, shotDisposalLabel, lookLabel, glassLabel, accentLabel, strokeLabel, strokeColorLabel, quackSwitch.label, quackRepeat.label, quackThrough]
            + clipRows.map(\.label)
        inkLabels.forEach { $0.textColor = UtkaChrome.ink }
        let dimLabels = [soundCaption, searchCaption, translateCaption, soundNote, nativeNote, nativeState, clipSecretsCaption, quackCaption]
        dimLabels.forEach { $0.textColor = UtkaChrome.dim }
        updateLine.textColor = updateIsCurrent ? UtkaChrome.ink : UtkaChrome.dim
        clipAge.textColor = UtkaChrome.ink
        quackAge.textColor = UtkaChrome.ink
        lookMode.selectedSegment = IslandLook.mode.rawValue
        glassSlider.doubleValue = IslandLook.glass
        if !accentWell.isActive { accentWell.color = IslandLook.accent }
        strokeSwitch.state = IslandLook.strokeOn ? .on : .off
        if !strokeWell.isActive { strokeWell.color = IslandLook.strokeColor }
        paintSidebar()
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

    /// Как работает перевод, под ним — пакет: установлен или кнопка скачать.
    private func layoutTranslate(text: NSRect, y: CGFloat) -> CGFloat {
        let height = fieldHeight(translateCaption, width: text.width)
        translateCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: height)
        return layoutTranslatePack(text: text, y: y + height + 14)
    }

    /// Блок своего движка перевода.
    private func layoutTranslatePack(text: NSRect, y: CGFloat) -> CGFloat {
        var y = y
        if NativeTranslate.isInstalled {
            return layoutInstalled(nativeReady, nativeCheck, text: text, y: y)
        }
        nativeTitle.frame = NSRect(x: text.minX, y: y, width: text.width - 88, height: 16)
        nativeState.frame = NSRect(x: text.maxX - 88, y: y, width: 88, height: 16)
        y += 22
        if !nativeButton.isHidden {
            nativeButton.frame = NSRect(x: text.minX, y: y, width: buttonWidth(nativeButton), height: 28)
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
        let updateWidth = buttonWidth(updateButton)
        let restoreWidth = buttonWidth(restoreButton)
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
            if updateIsCurrent {
                let labelWidth = text.width - 24
                let height = fieldHeight(updateLine, width: labelWidth)
                updateCheck.frame = NSRect(x: text.minX, y: y, width: 18, height: 18)
                updateLine.frame = NSRect(x: text.minX + 24, y: y, width: labelWidth, height: height)
                y += max(22, height) + 8
            } else {
                let measured = (updateLine.stringValue as NSString).boundingRect(
                    with: NSSize(width: text.width, height: 128),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: updateLine.font as Any]
                )
                let height = min(128, max(16, ceil(measured.height)))
                updateLine.frame = NSRect(x: text.minX, y: y, width: text.width, height: height)
                y += height + 8
            }
        }
        if !installButton.isHidden {
            installButton.frame = NSRect(x: text.minX, y: y, width: buttonWidth(installButton), height: 28)
            y += 36
        }
        return y
    }

    /// Тумблер про карточку. Выбор, куда девать файл, — только когда карточка уходит.
    private func layoutShot(text: NSRect, y: CGFloat) -> CGFloat {
        var y = layoutWrappedToggle(shotCleanupLabel, shotCleanup, text: text, y: y)
        guard shotCleanup.state == .on else { return y + 8 }
        y += 18
        shotDisposalLabel.frame = NSRect(x: text.minX, y: y, width: text.width, height: 18)
        y += 26
        shotDisposal.frame = NSRect(x: text.minX, y: y, width: min(280, text.width), height: 24)
        return y + 32
    }

    /// Тумблеры буфера сверху вниз. Число и единица срока — под своим тумблером, пока он включён.
    private func layoutClipboard(text: NSRect, y: CGFloat) -> CGFloat {
        let gap: CGFloat = 12
        var y = layoutToggle(clipRemember.label, clipRemember.toggle, text: text, y: y) + gap
        y = layoutToggle(clipSecrets.label, clipSecrets.toggle, text: text, y: y) + 2
        let captionHeight = fieldHeight(clipSecretsCaption, width: text.width)
        clipSecretsCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: captionHeight)
        y += captionHeight + gap
        y = layoutToggle(clipExpire.label, clipExpire.toggle, text: text, y: y)
        if clipExpire.toggle.state == .on {
            y += 8
            let row: CGFloat = 24
            let ageHeight = ceil(clipAge.fittingSize.height)
            clipAge.frame = NSRect(x: text.minX, y: y + (row - ageHeight) / 2, width: 52, height: ageHeight)
            clipAgeUnit.frame = NSRect(x: text.minX + 60, y: y, width: min(220, text.width - 60), height: row)
            y += row
        }
        y = layoutToggle(clipReboot.label, clipReboot.toggle, text: text, y: y + gap) + gap
        y = layoutToggle(clipConfirm.label, clipConfirm.toggle, text: text, y: y)
        return y + 8
    }

    /// Крякер, повтор и интервал «через».
    private func layoutCalendar(text: NSRect, y: CGFloat) -> CGFloat {
        var y = layoutToggle(quackSwitch.label, quackSwitch.toggle, text: text, y: y) + 8
        let captionHeight = fieldHeight(quackCaption, width: text.width)
        quackCaption.frame = NSRect(x: text.minX, y: y, width: text.width, height: captionHeight)
        y += captionHeight + 10
        guard quackSwitch.toggle.state == .on else { return y + 8 }
        y = layoutToggle(quackRepeat.label, quackRepeat.toggle, text: text, y: y)
        guard quackRepeat.toggle.state == .on else { return y + 8 }
        y += 8
        let row: CGFloat = 24
        quackThrough.sizeToFit()
        let throughW = max(40, ceil(quackThrough.fittingSize.width))
        let ageHeight = ceil(quackAge.fittingSize.height)
        quackThrough.frame = NSRect(x: text.minX, y: y + (row - 18) / 2, width: throughW, height: 18)
        quackAge.frame = NSRect(x: text.minX + throughW + 8, y: y + (row - ageHeight) / 2, width: 52, height: ageHeight)
        quackAgeUnit.frame = NSRect(
            x: text.minX + throughW + 68,
            y: y,
            width: min(220, text.width - throughW - 68),
            height: row
        )
        return y + row + 8
    }

    /// Длинная подпись переносится, а не обрезается многоточием.
    private func layoutWrappedToggle(_ label: NSTextField, _ toggle: NSSwitch, text: NSRect, y: CGFloat) -> CGFloat {
        let switchSize = toggle.fittingSize
        let gap: CGFloat = 12
        let labelWidth = max(80, text.width - switchSize.width - gap)
        label.preferredMaxLayoutWidth = labelWidth
        let measured = (label.stringValue as NSString).boundingRect(
            with: NSSize(width: labelWidth, height: 48),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font as Any]
        )
        let labelHeight = max(18, ceil(measured.height))
        let row = max(labelHeight, switchSize.height)
        label.frame = NSRect(x: text.minX, y: y + (row - labelHeight) / 2, width: labelWidth, height: labelHeight)
        toggle.frame = NSRect(
            x: text.maxX - switchSize.width,
            y: y + (row - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        return y + row
    }

    /// Поле-подпись по умолчанию в одну строку. Здесь нужно две.
    private func allowWrap(_ label: NSTextField) {
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.cell?.isScrollable = false
    }

    /// Держит верх окна на месте. Высота ставится кадром, без системного аниматора.
    private func fitWindow(contentBottom: CGFloat) {
        let height = max(300, contentBottom + 28)
        let frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: true)
    }

}

/// Ряд настроек: подпись слева, тумблер справа.
private struct SwitchRow {
    /// Подпись тем же гротеском и весом, что у «Звук» / «Поиск».
    let label: NSTextField
    /// Сам тумблер.
    let toggle = NSSwitch()

    init(_ title: String) {
        label = UtkaChrome.label(title, size: 13, weight: .semibold)
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

/// Пункт бокового меню. Подпись с одного левого края, клик по всей строке.
private final class MenuRow: NSView {
    let titleLabel: NSTextField
    let rowTag: Int
    var textInset: CGFloat = 12 { didSet { needsLayout = true } }
    var onClick: (() -> Void)?

    init(title: String, rowTag: Int) {
        self.rowTag = rowTag
        titleLabel = UtkaChrome.label(title, size: 13, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        let still = StillLayer()
        layer?.actions = [
            "bounds": still,
            "position": still,
            "opacity": still
        ]
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let textHeight: CGFloat = 18
        titleLabel.frame = NSRect(
            x: textInset,
            y: (bounds.height - textHeight) / 2,
            width: max(24, bounds.width - textInset - 28),
            height: textHeight
        )
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }
}

/// Пустое действие слоя: кадры меню ставит таймер, не аниматор Core Animation.
private final class StillLayer: NSObject, CAAction {
    func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {}
}

/// Значок меню. Клики проходят к пункту под ним.
private final class SidebarGlyph: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Строка раздела островка: иконка, имя, тумблер. Строку тащат целиком, чтобы переставить.
private final class SectionLine: NSView {
    let slot: SectionSlot
    var onDrag: ((CGFloat) -> Void)?
    var onDrop: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let toggle = NSSwitch()
    private let removeButton = NSButton()
    private var grab: CGFloat = 0
    private var shown = true

    init(slot: SectionSlot) {
        self.slot = slot
        titleLabel = UtkaChrome.label(slot.listTitle, size: 13, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let still = StillLayer()
        layer?.actions = [
            "bounds": still,
            "position": still,
            "backgroundColor": still,
            "transform": still,
            "shadowOpacity": still,
            "shadowRadius": still,
            "shadowOffset": still,
            "shadowPath": still,
            "shadowColor": still
        ]
        icon.image = utkaSymbol(slot.symbol, point: 15, label: slot.listTitle)
        icon.imageScaling = .scaleProportionallyDown
        toggle.target = self
        toggle.action = #selector(toggled)
        removeButton.title = "Снять"
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.font = UtkaChrome.font(11, weight: .medium)
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.isHidden = slot.core != nil
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(toggle)
        addSubview(removeButton)
        applyLook()
    }

    required init?(coder: NSCoder) { nil }

    /// Тень на время перетаскивания. Ноль — карточка снова лежит в слоте.
    func setLift(_ amount: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(0.32 * amount)
        layer?.shadowRadius = 12 * amount
        layer?.shadowOffset = CGSize(width: 0, height: -4 * amount)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        CATransaction.commit()
    }

    /// Включён — раздел на островке. Последний включённый тумблер не нажимается.
    func setShown(_ on: Bool, enabled: Bool, canRemove: Bool) {
        shown = on
        toggle.state = on ? .on : .off
        toggle.isEnabled = enabled
        removeButton.isEnabled = canRemove
        applyShown()
    }

    /// Подтягивает строку под текущую тему.
    func applyLook() {
        layer?.backgroundColor = UtkaChrome.card.cgColor
        applyShown()
    }

    private func applyShown() {
        let color = shown ? UtkaChrome.ink : UtkaChrome.dim
        titleLabel.textColor = color
        icon.contentTintColor = color
    }

    @objc private func toggled() {
        onToggle?(toggle.state == .on)
    }

    @objc private func removeClicked() {
        onRemove?()
    }

    override func layout() {
        super.layout()
        let side = min(18, bounds.height - 8)
        icon.frame = NSRect(x: 12, y: (bounds.height - side) / 2, width: side, height: side)
        var switchSize = toggle.fittingSize
        if switchSize.width < 8 { switchSize = NSSize(width: 38, height: 22) }
        toggle.frame = NSRect(
            x: bounds.width - 12 - switchSize.width,
            y: (bounds.height - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        if !removeButton.isHidden {
            let size = removeButton.fittingSize
            let width = ceil(size.width) + 4
            removeButton.frame = NSRect(
                x: toggle.frame.minX - 12 - width,
                y: (bounds.height - size.height) / 2,
                width: width,
                height: size.height
            )
        }
        let titleStop = removeButton.isHidden ? toggle.frame.minX : removeButton.frame.minX
        titleLabel.frame = NSRect(x: 40, y: (bounds.height - 18) / 2, width: max(40, titleStop - 48), height: 18)
    }

    /// Рука захвата — по всей строке, кроме кнопки «Снять» и тумблера.
    override func resetCursorRects() {
        let drag = NSRect(x: 0, y: 0, width: max(0, toggle.frame.minX), height: bounds.height)
        guard !removeButton.isHidden else {
            addCursorRect(drag, cursor: .openHand)
            return
        }
        let button = removeButton.frame.insetBy(dx: -4, dy: -4)
        addCursorRect(NSRect(x: 0, y: 0, width: max(0, button.minX), height: bounds.height), cursor: .openHand)
        addCursorRect(NSRect(x: button.maxX, y: 0, width: max(0, drag.maxX - button.maxX), height: bounds.height), cursor: .openHand)
        addCursorRect(button, cursor: .arrow)
    }

    /// Окно двигается за фон. Строку за фон не считаем, иначе вместо перестановки едет окно.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Иконка и имя не перехватывают нажатие: тащится вся строка. Тумблер и «Снять» остаются кнопками.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        let controls: [NSView] = [toggle, removeButton]
        if controls.contains(where: { !$0.isHidden && (hit === $0 || hit.isDescendant(of: $0)) }) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        grab = bounds.height - local.y
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        let point = parent.convert(event.locationInWindow, from: nil)
        onDrag?(point.y - grab)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDrop?()
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

/// Карточка каталога, которую ещё не поставили.
private final class LibraryOfferLine: NSView {
    var onInstall: (() -> Void)?
    private let icon = NSImageView()
    private let titleLabel: NSTextField
    private let install = NSButton()

    init(card: LibraryCard) {
        titleLabel = UtkaChrome.label(card.title, size: 13, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.image = utkaSymbol(card.symbol, point: 15, label: card.title)
        icon.imageScaling = .scaleProportionallyDown
        install.title = "Поставить"
        install.bezelStyle = .rounded
        install.font = UtkaChrome.font(12, weight: .medium)
        install.target = self
        install.action = #selector(installClicked)
        addSubview(icon)
        addSubview(titleLabel)
        addSubview(install)
        applyLook()
    }

    required init?(coder: NSCoder) { nil }

    /// Подтягивает строку под текущую тему.
    func applyLook() {
        layer?.backgroundColor = UtkaChrome.card.cgColor
        icon.contentTintColor = UtkaChrome.ink
        titleLabel.textColor = UtkaChrome.ink
    }

    @objc private func installClicked() {
        onInstall?()
    }

    override func layout() {
        super.layout()
        let side = min(18, bounds.height - 8)
        icon.frame = NSRect(x: 12, y: (bounds.height - side) / 2, width: side, height: side)
        install.sizeToFit()
        var buttonSize = install.frame.size
        if buttonSize.width < 8 { buttonSize = NSSize(width: 92, height: 24) }
        install.frame = NSRect(
            x: bounds.width - 12 - buttonSize.width,
            y: (bounds.height - buttonSize.height) / 2,
            width: buttonSize.width,
            height: buttonSize.height
        )
        titleLabel.frame = NSRect(x: 40, y: (bounds.height - 18) / 2, width: max(40, install.frame.minX - 48), height: 18)
    }
}
