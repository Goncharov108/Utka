import AppKit

struct TranslateFailure: Error {
    var message: String
}

/// Офлайн-перевод системной моделью en↔ru. Пакет лежит в ~/Library/Translation.
enum SystemTextTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        guard dlopen("/System/Library/Frameworks/Translation.framework/Versions/A/Translation", RTLD_NOW) != nil,
              let raw = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else {
            return .failure(TranslateFailure(message: "language"))
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Maker = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
        typealias Flag = @convention(c) (AnyObject, Selector, Int8) -> Void
        typealias Run = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let getter = unsafeBitCast(raw, to: Getter.self)
        let maker = unsafeBitCast(raw, to: Maker.self)
        let flag = unsafeBitCast(raw, to: Flag.self)
        let run = unsafeBitCast(raw, to: Run.self)
        guard let cls = objc_getClass("_LTTextSession") as AnyObject? else {
            return .failure(TranslateFailure(message: "language"))
        }
        let source = toEnglish ? "ru_RU" : "en_US"
        let target = toEnglish ? "en_US" : "ru_RU"
        guard let session = maker(
            getter(cls, sel_registerName("alloc"))!,
            sel_registerName("initWithSourceLocale:targetLocale:"),
            NSLocale(localeIdentifier: source),
            NSLocale(localeIdentifier: target)
        ) else {
            return .failure(TranslateFailure(message: "language"))
        }
        flag(session, sel_registerName("setAllowOnlineTranslation:"), 0)
        let box = TranslateBox()
        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { result, error in
            if let result = result {
                box.text = getter(result, sel_registerName("targetText")) as? String
            }
            if box.text == nil {
                box.error = (error as? NSError)?.localizedDescription ?? "language"
            }
            box.gate.signal()
        }
        run(session, sel_registerName("translateString:completionHandler:"), trimmed as NSString, unsafeBitCast(done, to: AnyObject.self))
        if box.gate.wait(timeout: .now() + 20) == .timedOut {
            return .failure(TranslateFailure(message: "timeout"))
        }
        if let text = box.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return .success(text)
        }
        return .failure(TranslateFailure(message: box.error ?? "language"))
    }
}

/// Ждёт ответ переводчика из фонового потока.
private final class TranslateBox {
    let gate = DispatchSemaphore(value: 0)
    var text: String?
    var error: String?
}

/// Запасной путь через «Команды», если системная модель недоступна.
enum ShortcutTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        let system = SystemTextTranslate.translate(trimmed, toEnglish: toEnglish)
        if case .success(let value) = system, !value.isEmpty {
            return .success(value)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("utka-tr-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("in.shortcut")
            let signed = dir.appendingPathComponent("Utka Translate.shortcut")
            let input = dir.appendingPathComponent("in.txt")
            let output = dir.appendingPathComponent("out.txt")
            try Data(plist(toEnglish: toEnglish)).write(to: source)
            try Data(trimmed.utf8).write(to: input)
            let signedRun = run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", source.path, "--output", signed.path])
            guard signedRun.code == 0 else { return .failure(TranslateFailure(message: signedRun.err)) }
            prepareInstalledShortcut(toEnglish: toEnglish)
            let named = run("/usr/bin/shortcuts", ["run", "Utka Translate", "--input-path", input.path, "--output-path", output.path, "--output-type", "public.utf8-plain-text"])
            let ran = named.code == 0 ? named : run("/usr/bin/shortcuts", ["run", signed.path, "--input-path", input.path, "--output-path", output.path])
            guard ran.code == 0 else {
                offerShortcut(signed)
                return .failure(TranslateFailure(message: ran.err.isEmpty ? ran.out : ran.err))
            }
            let value = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                offerLanguageSettings()
                return .failure(TranslateFailure(message: "language"))
            }
            return .success(value)
        } catch {
            return .failure(TranslateFailure(message: error.localizedDescription))
        }
    }

    /// Действие перевода на английский. Русский получается заменой English/en_US той же длины.
    private static let englishActionTemplate = "YnBsaXN0MDChAdICAwQFXxAaV0ZXb3JrZmxvd0FjdGlvbklkZW50aWZpZXJfEBpXRldvcmtmbG93QWN0aW9uUGFyYW1ldGVyc18QImlzLndvcmtmbG93LmFjdGlvbnMudGV4dC50cmFuc2xhdGXTBgcICRYdV1dGSW5wdXRfEBJXRlNlbGVjdGVkTGFuZ3VhZ2VUVVVJRNIKCwwVVVZhbHVlXxATV0ZTZXJpYWxpemF0aW9uVHlwZdINDg8QVnN0cmluZ18QEmF0dGFjaG1lbnRzQnlSYW5nZWH//NERElZ7MCwgMX3RExRUVHlwZV5FeHRlbnNpb25JbnB1dF8QEVdGVGV4dFRva2VuU3RyaW5n0goLFxzSGBkaG1pXRkxhbmd1YWdlWFdGTG9jYWxlV0VuZ2xpc2hVZW5fVVNfEBZXRkRpY3Rpb25hcnlGaWVsZFZhbHVlXxAkOTQ3NDJGQTgtRUYzQi00QkVFLUEwOTctOTIzRkREMkRFNkY5AAgACgAPACwASQBuAHUAfQCSAJcAnACiALgAvQDEANkA3ADfAOYA6QDuAP0BEQEWARsBJgEvATcBPQFWAAAAAAAAAgEAAAAAAAAAHgAAAAAAAAAAAAAAAAAAAX0="

    /// Подставляет язык в уже установленную команду. Длины слов совпадают, поэтому список не разъезжается.
    private static func prepareInstalledShortcut(toEnglish: Bool) {
        guard var bytes = Data(base64Encoded: englishActionTemplate) else { return }
        if !toEnglish {
            bytes = replacing(bytes, "English", with: "Russian")
            bytes = replacing(bytes, "en_US", with: "ru_RU")
        }
        let db = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Shortcuts/Shortcuts.sqlite")
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let sql = """
        UPDATE ZSHORTCUTACTIONS SET ZDATA=X'\(hex)' WHERE ZSHORTCUT IN (SELECT Z_PK FROM ZSHORTCUT WHERE ZNAME='Utka Translate');
        """
        _ = run("/usr/bin/sqlite3", [db.path, sql])
    }

    private static func replacing(_ data: Data, _ from: String, with to: String) -> Data {
        let source = Array(from.utf8)
        let target = Array(to.utf8)
        guard source.count == target.count else { return data }
        var bytes = [UInt8](data)
        var index = 0
        while index + source.count <= bytes.count {
            if Array(bytes[index..<(index + source.count)]) == source {
                bytes.replaceSubrange(index..<(index + source.count), with: target)
                index += target.count
            } else {
                index += 1
            }
        }
        return Data(bytes)
    }

    /// Один раз открывает системные языки, где качается пакет перевода.
    private static func offerLanguageSettings() {
        let key = "offeredLanguagePack"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Один раз показывает файл команды, чтобы её можно было добавить.
    private static func offerShortcut(_ signed: URL) {
        let key = "offeredShortcut"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let dest = UtkaPaths.support.appendingPathComponent("Utka Translate.shortcut")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: signed, to: dest)
        NSWorkspace.shared.open(dest)
    }

    private static func plist(toEnglish: Bool) -> Data {
        let language = toEnglish ? "en_US" : "ru_RU"
        let name = toEnglish ? "English" : "Russian"
        let inputValue: [String: Any] = [
            "string": "\u{fffc}",
            "attachmentsByRange": [
                "{0, 1}": ["Type": "ExtensionInput"]
            ]
        ]
        let inputField: [String: Any] = [
            "Value": inputValue,
            "WFSerializationType": "WFTextTokenString"
        ]
        let languageField: [String: Any] = [
            "Value": [
                "WFLocale": language,
                "WFLanguage": name
            ],
            "WFSerializationType": "WFDictionaryFieldValue"
        ]
        let action: [String: Any] = [
            "WFWorkflowActionIdentifier": "is.workflow.actions.text.translate",
            "WFWorkflowActionParameters": [
                "WFInput": inputField,
                "WFSelectedLanguage": languageField
            ]
        ]
        let workflow: [String: Any] = [
            "WFWorkflowName": "Utka Translate",
            "WFWorkflowClientVersion": "2605.0.5",
            "WFWorkflowClientRelease": "15.0",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": [
                "WFWorkflowIconStartColor": 4282601983,
                "WFWorkflowIconGlyphNumber": 59511
            ],
            "WFWorkflowImportQuestions": [String](),
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowOutputContentItemClasses": [String](),
            "WFWorkflowTypes": ["NCWidget"],
            "WFWorkflowActions": [action]
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0)) ?? Data()
    }

    private static func run(_ launch: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            return (1, "", "timeout")
        }
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output, error)
    }
}

/// Поле перевода. Без меню «Правка» у агента Cmd+A само не доходит.
final class TranslateTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Два окна: слева английский, справа русский. Пишешь в одно — перевод сам падает в другое.
final class TranslatorView: NSView {
    private let englishScroll = NSScrollView()
    private let russianScroll = NSScrollView()
    private let english: TranslateTextView
    private let russian: TranslateTextView
    private let englishMark = UtkaChrome.label("En", size: 11, weight: .semibold, color: UtkaChrome.dim)
    private let russianMark = UtkaChrome.label("Ru", size: 11, weight: .semibold, color: UtkaChrome.dim)
    private let status = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var timer: Timer?
    private var ticket = 0
    private var applying = false

    private enum Side {
        case english, russian
    }

    override init(frame frameRect: NSRect) {
        english = TranslateTextView()
        russian = TranslateTextView()
        super.init(frame: frameRect)
        mount(english, in: englishScroll)
        mount(russian, in: russianScroll)
        wantsLayer = true
        style(english)
        style(russian)
        status.maximumNumberOfLines = 2
        addSubview(englishScroll)
        addSubview(russianScroll)
        addSubview(englishMark)
        addSubview(russianMark)
        addSubview(status)
        NotificationCenter.default.addObserver(self, selector: #selector(englishChanged), name: NSText.didChangeNotification, object: english)
        NotificationCenter.default.addObserver(self, selector: #selector(russianChanged), name: NSText.didChangeNotification, object: russian)
    }

    required init?(coder: NSCoder) { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a",
           let text = window?.firstResponder as? NSTextView {
            text.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        status.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 28)
        let gap: CGFloat = 8
        let rightInset: CGFloat = 36
        let height = max(40, bounds.height - 36)
        let width = floor((bounds.width - gap - rightInset) / 2)
        englishScroll.frame = NSRect(x: 0, y: 32, width: width, height: height)
        russianScroll.frame = NSRect(x: width + gap, y: 32, width: width, height: height)
        englishMark.frame = NSRect(x: englishScroll.frame.minX + 8, y: englishScroll.frame.maxY - 18, width: 24, height: 14)
        russianMark.alignment = .right
        russianMark.frame = NSRect(x: russianScroll.frame.maxX - 32, y: russianScroll.frame.maxY - 18, width: 24, height: 14)
    }

    /// Кладёт текстовое поле в прокрутку.
    private func mount(_ text: NSTextView, in scroll: NSScrollView) {
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = text
    }

    private func style(_ text: NSTextView) {
        text.font = UtkaChrome.font(13)
        text.textColor = .white
        text.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        text.insertionPointColor = .white
        text.isRichText = false
        text.isEditable = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 8, height: 18)
    }

    @objc private func englishChanged() {
        schedule(from: .english)
    }

    @objc private func russianChanged() {
        schedule(from: .russian)
    }

    private func schedule(from side: Side) {
        guard !applying else { return }
        ticket += 1
        let current = ticket
        timer?.invalidate()
        let source = side == .english ? english : russian
        let text = source.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setTranslation("", on: side == .english ? .russian : .english)
            status.stringValue = ""
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.run(ticket: current, text: text, from: side)
        }
    }

    private func run(ticket current: Int, text: String, from side: Side) {
        let toEnglish = side == .russian
        status.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShortcutTranslate.translate(text, toEnglish: toEnglish)
            DispatchQueue.main.async { [weak self] in
                guard let view = self, view.ticket == current else { return }
                switch result {
                case .success(let value):
                    view.setTranslation(value, on: side == .english ? .russian : .english)
                    view.status.stringValue = ""
                case .failure(let error):
                    view.status.stringValue = Self.message(for: error.message)
                }
            }
        }
    }

    /// Пишет перевод в другое окно и не запускает обратный запрос.
    private func setTranslation(_ text: String, on side: Side) {
        applying = true
        let view = side == .english ? english : russian
        view.string = text
        applying = false
    }

    private static func message(for raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("language") || lower.contains("locale") || raw.contains("язык") || raw.contains("пакет") || raw.isEmpty {
            return "Языковой пакет ещё не скачан"
        }
        return "Не удалось перевести"
    }
}
