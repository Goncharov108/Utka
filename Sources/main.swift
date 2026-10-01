import AppKit
import Darwin

/// Сборка агента: жест, островок, четыре раздела, иконка в строке меню.
final class UtkaApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var hover: HoverMonitor!
    private var panel: IslandPanel!
    private var history: ClipboardHistory!
    private var shelf: ShelfModel!
    private var presets: PresetsModel!
    private var presetsView: PresetsView!
    private var reminder: ReminderEngine!
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var reminderItem: NSMenuItem!
    private var statusImage: NSImage?
    private var blinkTimer: Timer?
    private let settings = SettingsPanel()
    private var capturing = false
    private var askingCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let support = UtkaPaths.support
        history = ClipboardHistory(storeURL: support.appendingPathComponent("clipboard.json"))
        shelf = ShelfModel(storeURL: support.appendingPathComponent("shelf.json"))
        settings.onDeleteShotAfterUse = { [weak shelf] on in
            shelf?.setDeleteShotAfterUse(on)
        }
        settings.onShotDisposal = { [weak shelf] disposal in
            shelf?.setShotDisposal(disposal)
        }
        settings.onClipboardPrefs = { [weak history] in
            history?.applyPrefs()
        }
        ShotEditor.shelf = shelf
        presets = PresetsModel(storeURL: support.appendingPathComponent("presets.json"))

        let shelfView = ShelfView(model: shelf)
        let clipboardView = ClipboardView(history: history)
        presetsView = PresetsView(model: presets)
        presetsView.copyText = { [weak self] text in self?.history.copyToPasteboard(text) }
        reminder = ReminderEngine(model: presets)
        presetsView.onAlarmOpened = { [weak self] id in self?.reminder.acknowledge(id: id) }
        let translator = TranslatorView()
        let mark = Bundle.main.url(forResource: "utka-mark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

        SectionBoard.reload()
        hover = HoverMonitor()
        panel = IslandPanel(shelf: shelfView, clipboard: clipboardView, presets: presetsView, translator: translator, mark: mark)
        settings.onIslandBar = { [weak panel] in
            panel?.setBar()
        }
        panel.bindActions(target: self, action: #selector(sectionClicked(_:)))
        panel.onSection = { [weak self] section in
            if section == .presets { self?.presetsView.refresh() }
        }
        panel.onCapture = { [weak self] in self?.captureRegion() }
        panel.onSettings = { [weak self] in self?.showSettings() }
        shelfView.onDrag = { [weak self] active in self?.hover.suspended = active }
        clipboardView.onDrag = { [weak self] active in self?.hover.suspended = active }
        presetsView.onDrag = { [weak self] active in self?.hover.suspended = active }
        hover.extraHitRect = { [weak self] in
            guard let window = self?.panel.window, window.isVisible else { return nil }
            return window.frame
        }
        hover.onHot = { [weak self] screen in
            self?.panel.show(on: screen)
            self?.presetsView.refresh()
        }
        hover.onCold = { [weak self] in self?.panel.hide() }
        hover.enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true

        installStatusItem(mark: mark)
        reminder.onRingingChanged = { [weak self] id in self?.ringingChanged(id) }
        reminder.start()
        history.start()
        shelf.startScreenshotWatch()
        hover.start()
        resumeCaptureIfGranted()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, self?.panel.window.isKeyWindow == true else { return event }
            self?.panel.hide()
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioOutput.shared.shutdown()
    }

    private func installStatusItem(mark: NSImage?) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = mark.map { MenuMark.template(from: $0) } ?? NSImage(systemSymbolName: "bird", accessibilityDescription: "Утка")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusImage = image
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !hover.enabled
        let menu = NSMenu()
        menu.delegate = self
        reminderItem = NSMenuItem(title: "", action: #selector(openRinging), keyEquivalent: "")
        reminderItem.target = self
        reminderItem.isHidden = true
        menu.addItem(reminderItem)
        toggleItem = NSMenuItem(title: "Включена", action: #selector(toggleEnabled), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        let show = NSMenuItem(title: "Показать", action: #selector(showNow), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let settingsItem = NSMenuItem(title: "Настройки", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.state = hover.enabled ? .on : .off
        statusItem.button?.appearsDisabled = !hover.enabled
    }

    /// Утка кричит — мигает значком в строке меню и открывает пункт быстрого перехода.
    private func ringingChanged(_ id: String?) {
        presetsView.ringingID = id
        reminderItem.isHidden = id == nil
        reminderItem.title = id.flatMap { ringingID in
            presets.texts.first { $0.id == ringingID }.map { "⏰ \($0.title) — показать" }
        } ?? ""
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard id != nil else {
            statusItem.button?.alphaValue = 1
            return
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.statusItem.button?.alphaValue = (self.statusItem.button?.alphaValue ?? 1) < 1 ? 1 : 0.35
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Пункт меню «⏰ … — показать»: открывает островок на этой заметке и гасит крик.
    @objc private func openRinging() {
        guard let id = reminder.ringingID else { return }
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        setEnabled(true)
        panel.show(on: screen)
        panel.select(slotID: IslandSection.presets.slotID)
        presetsView.openNote(id: id)
        reminder.acknowledge(id: id)
    }

    @objc private func showNow() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let screen else { return }
        setEnabled(true)
        panel.show(on: screen)
    }

    @objc private func toggleEnabled() {
        setEnabled(!hover.enabled)
    }

    /// Включает жест из меню строки.
    private func setEnabled(_ on: Bool) {
        hover.enabled = on
        UserDefaults.standard.set(on, forKey: "enabled")
        toggleItem.state = on ? .on : .off
        statusItem.button?.appearsDisabled = !on
        if !on { panel.hide() }
    }

    /// Окно настроек на том экране, где открыт островок.
    private func showSettings() {
        settings.show(on: panel.window.screen)
    }

    /// То же окно из меню строки, на экране под курсором.
    @objc private func openSettingsFromMenu() {
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? panel.window.screen
        settings.show(on: screen)
    }

    /// Если доступ уже выдали живому процессу — сразу открыть крестик.
    private func resumeCaptureIfGranted() {
        guard UserDefaults.standard.bool(forKey: AreaShot.pendingKey) else { return }
        UserDefaults.standard.set(false, forKey: AreaShot.pendingKey)
        guard CGPreflightScreenCaptureAccess() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.captureRegion()
        }
    }

    /// Прячет островок и открывает системный выбор области. Без доступа окна на снимке пустые, поэтому снимок не запускается.
    private func captureRegion() {
        guard !capturing, !askingCapture else { return }
        if !CGPreflightScreenCaptureAccess() {
            requestCaptureAccess()
            return
        }
        capturing = true
        hover.suspended = true
        hover.markClosed()
        panel.dismiss()
        let file = AreaShot.destination()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                DispatchQueue.main.async {
                    self?.capturing = false
                    self?.hover.suspended = false
                }
            }
            AreaShot.runInteractive(to: file)
        }
    }

    /// Просит доступ и перезапускает утку, когда его дали. Старый процесс разрешение не подхватывает.
    private func requestCaptureAccess() {
        askingCapture = true
        CGRequestScreenCaptureAccess()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var granted = false
            for _ in 0..<45 {
                if AreaShot.freshProcessHasAccess() {
                    granted = true
                    break
                }
                Thread.sleep(forTimeInterval: 1)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.askingCapture = false
                guard granted else {
                    self.showCaptureDenied()
                    return
                }
                UserDefaults.standard.set(true, forKey: AreaShot.pendingKey)
                AreaShot.relaunch()
            }
        }
    }

    /// Говорит, что запись экрана так и не включилась, и открывает системный переключатель.
    private func showCaptureDenied() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Запись экрана не включена"
        alert.informativeText = "Системные настройки → Конфиденциальность и безопасность → Запись экрана. Включи Утку. Если переключатель уже стоит, в Терминале: tccutil reset ScreenCapture dev.goncharov.utka"
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "ОК")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func sectionClicked(_ sender: NSButton) {
        guard let section = sender as? SectionRailButton else { return }
        panel.openSection(section)
    }
}

enum SelfCheck {
    static var failed = false

    static func run() {
        checkZones()
        checkBookmark()
        checkClipboard()
        checkMark()
        checkSpot()
        if failed {
            fputs("SELF-CHECK FAILED\n", stderr)
        } else {
            print("SELF-CHECK OK")
        }
    }

    private static func checkZones() {
        let screens = NSScreen.screens
        if screens.isEmpty {
            fail("нет экранов")
            return
        }
        for screen in screens {
            let zone = HoverMonitor.zone(for: screen)
            print("screen \(screen.localizedName) frame \(screen.frame) zone \(zone)")
            let body = zone.insetBy(dx: 0, dy: 4)
            if !screen.frame.contains(body) { fail("зона вне экрана \(screen.localizedName)") }
            if abs(zone.midX - screen.frame.midX) > 1 { fail("зона не по центру") }
            if zone.maxY < screen.frame.maxY { fail("зона не у верхнего края") }
            if zone.width < 480 { fail("ширина зоны \(zone.width)") }
        }
    }

    private static func checkBookmark() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utka-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        do {
            try Data("hi".utf8).write(to: file)
            guard let data = BookmarkStore.data(for: file), let url = BookmarkStore.url(from: data) else {
                fail("закладка")
                return
            }
            if url.path != file.path && url.standardizedFileURL.path != file.standardizedFileURL.path {
                fail("закладка разрешилась не туда: \(url.path)")
            }
        } catch {
            fail("запись файла проверки")
        }
    }

    /// Отдельные настройки самопроверки. В конце стираются, настоящие настройки утки не трогаются.
    private static let prefsSuite = "dev.goncharov.utka.selfcheck"

    /// История буфера во временной папке и на отдельных настройках.
    private static func checkClipboard() {
        guard let defaults = UserDefaults(suiteName: prefsSuite) else {
            fail("нет отдельных настроек самопроверки")
            return
        }
        defaults.removePersistentDomain(forName: prefsSuite)
        defer { defaults.removePersistentDomain(forName: prefsSuite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utka-clip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let prefs = ClipboardPrefs(defaults: defaults)
        checkClipboardPrefs(prefs)
        let history = scratchHistory(dir, prefs)
        history.consider(text: "a")
        history.consider(text: "a")
        history.consider(text: "  ")
        history.consider(text: "file", types: [NSPasteboard.PasteboardType.fileURL.rawValue])
        history.consider(text: "b")
        let texts = history.items.map(\.text)
        if texts != ["b", "a"] { fail("история \(texts)") }
        for index in 0..<55 {
            history.consider(text: "n\(index)")
        }
        if history.items.count != 50 { fail("лимит \(history.items.count)") }
        if history.items.first?.text != "n54" { fail("порядок") }
        checkClipboardFilter(dir, prefs)
        checkClipboardAge(dir, prefs)
        checkClipboardLegacy(dir, prefs)
        checkClipboardReboot(dir, prefs)
    }

    /// Чистая история в своём файле временной папки.
    private static func scratchHistory(_ dir: URL, _ prefs: ClipboardPrefs) -> ClipboardHistory {
        ClipboardHistory(storeURL: dir.appendingPathComponent("\(UUID().uuidString).json"), prefs: prefs)
    }

    /// Значения по умолчанию, и неверное число срока не сохраняется.
    private static func checkClipboardPrefs(_ prefs: ClipboardPrefs) {
        let flags = [prefs.remember, prefs.skipSecrets, prefs.expires, !prefs.clearOnReboot, prefs.confirmClear]
        if flags.contains(false) || prefs.lifetime != 7 * 86_400 || prefs.ageUnit != .days {
            fail("настройки буфера по умолчанию")
        }
        for wrong in [0, 1_000, -5] {
            prefs.ageCount = wrong
        }
        if prefs.ageCount != 7 { fail("неверное число срока сохранилось: \(prefs.ageCount)") }
        prefs.ageCount = 999
        if prefs.ageCount != 999 { fail("999 не сохранилось") }
    }

    /// Скрытое не записывается при «Не сохранять пароли» и записывается без него. Временное и длинное — никогда.
    private static func checkClipboardFilter(_ dir: URL, _ prefs: ClipboardPrefs) {
        let plain = NSPasteboard.PasteboardType.string.rawValue
        let secrets = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "Pasteboard generator type", "net.antelle.keeweb"]
        for mark in secrets {
            if ClipboardHistory.accepts(types: [plain, mark], text: "x", skipSecrets: true) { fail("пропущена пометка пароля \(mark)") }
            if !ClipboardHistory.accepts(types: [plain, mark], text: "x", skipSecrets: false) { fail("без настройки отсеяно \(mark)") }
        }
        let history = scratchHistory(dir, prefs)
        prefs.skipSecrets = true
        history.consider(text: "пароль", types: [plain, "org.nspasteboard.ConcealedType"])
        if !history.items.isEmpty { fail("скрытое записалось \(history.items.map(\.text))") }
        prefs.skipSecrets = false
        history.consider(text: "пароль", types: [plain, "org.nspasteboard.ConcealedType"])
        if history.items.map(\.text) != ["пароль"] { fail("скрытое без «Не сохранять пароли» \(history.items.map(\.text))") }
        let long = String(repeating: "д", count: ClipboardHistory.textLimit + 1)
        for skip in [true, false] {
            prefs.skipSecrets = skip
            history.consider(text: "временное", types: [plain, "org.nspasteboard.TransientType"])
            history.consider(text: "сгенерированное", types: [plain, "org.nspasteboard.AutoGeneratedType"])
            history.consider(text: long, types: [plain])
        }
        if history.items.map(\.text) != ["пароль"] { fail("временное или длинное записалось: \(history.items.count)") }
        history.consider(text: String(repeating: "д", count: ClipboardHistory.textLimit), types: [plain])
        if history.items.first?.text.count != ClipboardHistory.textLimit { fail("ровно 100 000 символов не записались") }
    }

    /// Запись уходит, когда становится старше срока, свежие остаются. Без срока ничего не уходит.
    private static func checkClipboardAge(_ dir: URL, _ prefs: ClipboardPrefs) {
        let now = Date()
        let day: TimeInterval = 86_400
        prefs.expires = true
        prefs.ageCount = 7
        prefs.ageUnit = .days
        let url = dir.appendingPathComponent("age.json")
        let history = ClipboardHistory(storeURL: url, prefs: prefs)
        history.consider(text: "старая", at: now.addingTimeInterval(-7.5 * day))
        history.consider(text: "свежая", at: now.addingTimeInterval(-day))
        if history.items.map(\.text) != ["свежая", "старая"] { fail("срок раньше времени \(history.items.map(\.text))") }
        history.dropExpired(now: now)
        if history.items.map(\.text) != ["свежая"] { fail("срок 7 дней \(history.items.map(\.text))") }
        if ClipboardHistory(storeURL: url, prefs: prefs).items.map(\.text) != ["свежая"] { fail("срок не дошёл до файла") }
        history.dropExpired(now: now.addingTimeInterval(6.5 * day))
        if !history.items.isEmpty { fail("свежая не ушла, когда постарела") }
        prefs.ageUnit = .minutes
        prefs.ageCount = 5
        history.consider(text: "шесть минут", at: now.addingTimeInterval(-6 * 60))
        history.consider(text: "четыре минуты", at: now.addingTimeInterval(-4 * 60))
        history.dropExpired(now: now)
        if history.items.map(\.text) != ["четыре минуты"] { fail("срок 5 минут \(history.items.map(\.text))") }
        prefs.expires = false
        history.consider(text: "вечная", at: now.addingTimeInterval(-400 * day))
        let ageless = history.items.map(\.text)
        history.dropExpired(now: now)
        if ageless.first != "вечная" || history.items.map(\.text) != ageless { fail("без срока записи ушли \(history.items.map(\.text))") }
    }

    /// Старый clipboard.json без времени читается, записи получают время и сразу его сохраняют.
    private static func checkClipboardLegacy(_ dir: URL, _ prefs: ClipboardPrefs) {
        let url = dir.appendingPathComponent("legacy.json")
        try? Data(#"[{"id":"1","text":"первая"},{"id":"2","text":"вторая"}]"#.utf8).write(to: url)
        let opened = Date()
        let history = ClipboardHistory(storeURL: url, prefs: prefs)
        if history.items.map(\.text) != ["первая", "вторая"] { fail("старый файл \(history.items.map(\.text))") }
        let stamped = history.items.allSatisfy { item in
            guard let copiedAt = item.copiedAt else { return false }
            return abs(copiedAt.timeIntervalSince(opened)) < 60
        }
        if !stamped { fail("записи старого файла без времени") }
        let saved = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !saved.contains("copiedAt") { fail("время старых записей не сохранилось") }
    }

    /// Новое время загрузки системы чистит историю, только если «Чистить после перезагрузки» включено.
    private static func checkClipboardReboot(_ dir: URL, _ prefs: ClipboardPrefs) {
        if ClipboardHistory.rebooted(saved: nil, current: 1_000) { fail("первый запуск принят за перезагрузку") }
        if ClipboardHistory.rebooted(saved: 1_000, current: 1_030) { fail("подвод часов принят за перезагрузку") }
        if !ClipboardHistory.rebooted(saved: 1_000, current: 5_000) { fail("перезагрузка не замечена") }
        let history = scratchHistory(dir, prefs)
        prefs.bootTime = nil
        prefs.clearOnReboot = true
        history.consider(text: "до перезагрузки")
        history.noteBoot(1_000)
        history.noteBoot(1_000)
        if history.items.isEmpty { fail("история ушла без перезагрузки") }
        history.noteBoot(5_000)
        if !history.items.isEmpty { fail("перезагрузка при включённой настройке не почистила историю") }
        prefs.clearOnReboot = false
        history.consider(text: "после перезагрузки")
        let kept = history.items.map(\.text)
        history.noteBoot(9_000)
        if kept.isEmpty || history.items.map(\.text) != kept { fail("перезагрузка при выключенной настройке почистила историю") }
        if prefs.bootTime != 9_000 { fail("время загрузки не сохранилось: \(prefs.bootTime ?? 0)") }
    }

    /// Счёт и единицы отвечают сразу, без индекса Spotlight.
    private static func checkSpot() {
        let search = IslandSearch()
        let answers = [
            ("2+2", "4"), ("12*7", "84"), ("(2+3)*4", "20"), ("-3+5", "2"),
            ("10/4", "2.5"), ("1,5*2", "3"), ("2×3", "6"),
            ("99999999999*99999999999", String(format: "%g", 99999999999.0 * 99999999999.0))
        ]
        for (expr, answer) in answers {
            let first = search.preview(expr).first
            if first?.title != answer || first?.detail != "Калькулятор" {
                fail("калькулятор \(expr) → \(first?.title ?? "пусто")")
            }
        }
        for expr in ["2+", "(", ")", "-", "+", "2+*3", "2..5+1", "1/0", "()", "2**3", "((2)"] {
            if search.preview(expr).contains(where: { $0.detail == "Калькулятор" }) {
                fail("калькулятор ответил на «\(expr)»")
            }
        }
        let units = search.preview("10 км в м")
        if !units.contains(where: { $0.detail == "Перевод единиц" && $0.title.hasPrefix("10000") }) {
            fail("единицы \(units.map(\.title))")
        }
        if !search.preview("   ").isEmpty { fail("пустой запрос") }
        if !search.preview("2").isEmpty { fail("одиночная цифра не счёт") }
        let ranked = IslandSearch.ordered(
            [
                IslandHit(title: "определение", detail: "Словарь", url: nil, copy: nil),
                IslandHit(title: "сеть", detail: "Сеть", url: nil, copy: nil)
            ],
            [
                IslandHit(title: "Safari", detail: "Программа", url: nil, copy: nil),
                IslandHit(title: "чек", detail: "Файл", url: nil, copy: nil)
            ]
        )
        if ranked.map(\.title) != ["Safari", "определение", "чек", "сеть"] {
            fail("порядок \(ranked.map(\.title))")
        }
        if IslandSearch.acceptsPath("/Library/Receipts/com.apple.pkg.Safari.bom") { fail("чек в списке") }
        if !IslandSearch.acceptsPath("/Applications/Safari.app") { fail("программа отсечена") }
        if IslandSearch.score(name: "ChatGPT", query: "cht") == nil { fail("неточный набор") }
        if IslandSearch.score(name: "Notes", query: "cht") != nil { fail("ложное совпадение") }
        let folderRank = IslandSearch.ordered(
            [IslandHit(title: "сеть", detail: "Сеть", url: nil, copy: nil)],
            [
                IslandHit(title: "заметки goncharov", detail: "Файл", url: nil, copy: nil),
                IslandHit(title: "Goncharov", detail: "Папка", url: URL(fileURLWithPath: "/tmp/Goncharov"), copy: nil)
            ],
            query: "goncharov"
        )
        if folderRank.map(\.title) != ["Goncharov", "заметки goncharov", "сеть"] {
            fail("папка \(folderRank.map(\.title))")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("utka-spot-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch.appendingPathComponent("Goncharov"), withIntermediateDirectories: true)
        let walked = IslandSearch.names(in: [scratch], query: "goncharov")
        if !walked.contains(where: { $0.title == "Goncharov" && $0.detail == "Папка" }) {
            fail("обход \(walked.map(\.title))")
        }
        try? FileManager.default.removeItem(at: scratch)
        let apps = IslandSearch.readApps()
        if !apps.contains(where: { $0.path.hasSuffix("/Safari.app") }) {
            fail("нет Safari среди программ \(apps.count)")
        }
        let safari = IslandSearch.appHits(query: "saf", apps: apps, recent: [:])
        if safari.first?.title != "Safari" { fail("saf \(safari.map(\.title))") }
        let fuzzy = IslandSearch.appHits(
            query: "cht",
            apps: [("ChatGPT", "/Applications/ChatGPT.app")],
            recent: [:]
        )
        if fuzzy.first?.title != "ChatGPT" { fail("cht \(fuzzy.map(\.title))") }
        var last: [String] = ["x"]
        search.onHits = { hits in last = hits.map(\.title) }
        search.lookup("2+2")
        if last.first != "4" { fail("живой счёт \(last)") }
        search.lookup("")
        if !last.isEmpty { fail("очистка не гасит список") }
    }

    private static func checkMark() {
        guard let url = Bundle.main.url(forResource: "utka-mark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            fail("нет марки в бандле")
            return
        }
        let template = MenuMark.template(from: image)
        guard let data = MenuMark.pngData(template) else {
            fail("силуэт")
            return
        }
        let out = URL(fileURLWithPath: "/tmp/utka-menu-preview.png")
        try? data.write(to: out)
        print("menu mark \(data.count) bytes")
    }

    private static func fail(_ message: String) {
        failed = true
        fputs("FAIL \(message)\n", stderr)
    }
}

@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: UInt32) -> Int32

/// Системный выбор области. Снимок без доступа к записи экрана оставляет только обои.
enum AreaShot {
    static let pendingKey = "captureAfterGrant"

    /// Путь в папке утки, не на рабочем столе.
    static func destination() -> URL {
        let dir = UtkaPaths.support.appendingPathComponent("Shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return dir.appendingPathComponent("Снимок экрана \(stamp.string(from: Date())).png")
    }

    /// Крестик выбора. Процесс живёт, пока область не выбрана или не отменена.
    static func runInteractive(to file: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", file.path]
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        discardCancelledShot(file, status: task.terminationStatus)
    }

    /// Отмена крестика не должна оставлять пустой файл на полке.
    private static func discardCancelledShot(_ file: URL, status: Int32) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard status != 0 || size == 0 else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Новый процесс сам отвечает за разрешение. Ребёнок утки унаследовал бы отказ родителя.
    static func freshProcessHasAccess() -> Bool {
        guard let exe = Bundle.main.executablePath else { return false }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }
        guard responsibility_spawnattrs_setdisclaim(&attr, 1) == 0 else { return false }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        let arg0 = strdup(exe)
        let arg1 = strdup("--capture-access")
        defer {
            free(arg0)
            free(arg1)
        }
        var argv: [UnsafeMutablePointer<CChar>?] = [arg0, arg1, nil]
        var pid: pid_t = 0
        let rc: Int32 = argv.withUnsafeMutableBufferPointer { buf in
            posix_spawn(&pid, exe, &actions, &attr, buf.baseAddress, environ)
        }
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            return false
        }
        let data = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return String(data: data, encoding: .utf8)?.contains("yes") == true
    }

    /// Новая копия стартует после выхода этой, уже с записанным флагом снимка.
    static func relaunch() {
        UserDefaults.standard.synchronize()
        let pid = ProcessInfo.processInfo.processIdentifier
        let app = Bundle.main.bundlePath
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(app)\""
        guard spawnNewSession(script) else { return }
        NSApp.terminate(nil)
    }

    /// Оболочка в своей сессии, иначе выход утки оборвёт перезапуск.
    private static func spawnNewSession(_ script: String) -> Bool {
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }
        guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID)) == 0 else { return false }
        let sh = strdup("/bin/sh")
        let flag = strdup("-c")
        let cmd = strdup(script)
        defer {
            free(sh)
            free(flag)
            free(cmd)
        }
        guard sh != nil, flag != nil, cmd != nil else { return false }
        var argv: [UnsafeMutablePointer<CChar>?] = [sh, flag, cmd, nil]
        var pid: pid_t = 0
        let rc: Int32 = argv.withUnsafeMutableBufferPointer { buf in
            posix_spawn(&pid, "/bin/sh", nil, &attr, buf.baseAddress, environ)
        }
        return rc == 0
    }
}

if CommandLine.arguments.contains("--capture-access") {
    print(CGPreflightScreenCaptureAccess() ? "yes" : "no")
    exit(0)
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--self-check") {
    SelfCheck.run()
    exit(SelfCheck.failed ? 1 : 0)
}
if let index = CommandLine.arguments.firstIndex(of: "--translate"), CommandLine.arguments.count > index + 1 {
    let text = CommandLine.arguments[index + 1]
    let toEnglish = !CommandLine.arguments.contains("--ru")
    switch ShortcutTranslate.translate(text, toEnglish: toEnglish) {
    case .success(let value):
        print(value)
        exit(0)
    case .failure(let error):
        fputs(error.message + "\n", stderr)
        exit(1)
    }
}

if let bundleID = Bundle.main.bundleIdentifier {
    let own = ProcessInfo.processInfo.processIdentifier
    let twin = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        $0.processIdentifier != own && !$0.isTerminated
    }
    if let twin {
        fputs("Утка уже запущена (pid \(twin.processIdentifier))\n", stderr)
        exit(0)
    }
}

let delegate = UtkaApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
