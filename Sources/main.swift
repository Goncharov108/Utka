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
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
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
        ShotEditor.shelf = shelf
        presets = PresetsModel(storeURL: support.appendingPathComponent("presets.json"))

        let shelfView = ShelfView(model: shelf)
        let clipboardView = ClipboardView(history: history)
        presetsView = PresetsView(model: presets)
        presetsView.copyText = { [weak self] text in self?.history.copyToPasteboard(text) }
        let translator = TranslatorView()
        let mark = Bundle.main.url(forResource: "utka-mark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

        hover = HoverMonitor()
        panel = IslandPanel(shelf: shelfView, clipboard: clipboardView, presets: presetsView, translator: translator, mark: mark)
        settings.onIslandBar = { [weak panel] mode in
            panel?.setBar(mode)
        }
        panel.bindActions(target: self, action: #selector(sectionClicked(_:)))
        panel.onSection = { [weak self] section in
            if section == .presets { self?.presetsView.refresh() }
        }
        panel.onCapture = { [weak self] in self?.captureRegion() }
        panel.onSettings = { [weak self] in self?.showSettings() }
        shelfView.onDrag = { [weak self] active in self?.hover.suspended = active }
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
        history.startPolling()
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
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = !hover.enabled
        let menu = NSMenu()
        menu.delegate = self
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
        guard let section = IslandSection(rawValue: sender.tag) else { return }
        panel.select(section)
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

    private static func checkClipboard() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utka-clip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = ClipboardHistory(storeURL: dir.appendingPathComponent("clipboard.json"))
        history.consider(text: "a", hasFile: false)
        history.consider(text: "a", hasFile: false)
        history.consider(text: "  ", hasFile: false)
        history.consider(text: "file", hasFile: true)
        history.consider(text: "b", hasFile: false)
        let texts = history.items.map(\.text)
        if texts != ["b", "a"] { fail("история \(texts)") }
        for index in 0..<55 {
            history.consider(text: "n\(index)", hasFile: false)
        }
        if history.items.count != 50 { fail("лимит \(history.items.count)") }
        if history.items.first?.text != "n54" { fail("порядок") }
    }

    /// Счёт и единицы отвечают сразу, без индекса Spotlight.
    private static func checkSpot() {
        let search = IslandSearch()
        let calc = search.preview("2+2")
        if calc.first?.title != "4" || calc.first?.detail != "Калькулятор" {
            fail("калькулятор \(calc.map(\.title))")
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

let delegate = UtkaApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
