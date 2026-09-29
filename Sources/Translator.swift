import AppKit

struct TranslateFailure: Error {
    var message: String
}

/// Офлайн-перевод системной моделью en↔ru. Пакет лежит в ~/Library/Translation.
///
/// Класс `_LTTextSession` — приватный и не документированный: на части систем
/// (другая версия macOS, региональные ограничения на офлайн-модель) он может
/// не отвечать на ожидаемые методы. Вызов несуществующего метода через
/// objc_msgSend не бросает обычную Swift-ошибку — Objective-C кидает
/// исключение, которое ничем не поймать, и всё приложение падает разом.
/// Поэтому каждый метод проверяется через `responds(to:)`, прежде чем
/// вызывать его напрямую.
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
        guard let anyClass = objc_getClass("_LTTextSession"),
              let cls = unsafeBitCast(anyClass, to: AnyClass.self) as? NSObject.Type else {
            return .failure(TranslateFailure(message: "language"))
        }
        let initSelector = Selector(("initWithSourceLocale:targetLocale:"))
        guard cls.instancesRespond(to: initSelector) else {
            return .failure(TranslateFailure(message: "language"))
        }
        let source = toEnglish ? "ru_RU" : "en_US"
        let target = toEnglish ? "en_US" : "ru_RU"
        guard let session = maker(
            getter(cls, sel_registerName("alloc"))!,
            initSelector,
            NSLocale(localeIdentifier: source),
            NSLocale(localeIdentifier: target)
        ), let sessionObject = session as? NSObject else {
            return .failure(TranslateFailure(message: "language"))
        }
        let flagSelector = Selector(("setAllowOnlineTranslation:"))
        let runSelector = Selector(("translateString:completionHandler:"))
        guard sessionObject.responds(to: flagSelector), sessionObject.responds(to: runSelector) else {
            return .failure(TranslateFailure(message: "language"))
        }
        flag(session, flagSelector, 0)
        let box = TranslateBox()
        let done: @convention(block) (AnyObject?, AnyObject?) -> Void = { result, error in
            if let result = result,
               (result as? NSObject)?.responds(to: Selector(("targetText"))) == true {
                box.text = getter(result, sel_registerName("targetText")) as? String
            }
            if box.text == nil {
                box.error = (error as? NSError)?.localizedDescription ?? "language"
            }
            box.gate.signal()
        }
        run(session, runSelector, trimmed as NSString, unsafeBitCast(done, to: AnyObject.self))
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

/// Английский и русский в ~/Library/Translation. «Скачан» только если файл на диске не пустой.
enum LanguagePacks {
    struct Item {
        var title: String
        var ready: Bool
    }

    private static let minimumBytes = 100_000
    private static var pending: AnyObject?
    private static var pendingDone: AnyObject?

    /// Две строки для окна настроек.
    static func items() -> [Item] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Translation/AssetsV3", isDirectory: true)
        return [
            Item(title: "Английский", ready: containsPack(in: root, marks: ["en_us", "pb-en", "mt-en"])),
            Item(title: "Русский", ready: containsPack(in: root, marks: ["ru_ru", "pb-ru", "-ru.asset"]))
        ]
    }

    /// Качает модель en↔ru. nil значит вызов кончился без ошибки; подпись всё равно сверяется по диску.
    ///
    /// `_LTLocalePair` и `_LTTranslator` — приватные классы; каждый метод
    /// проверяется через `responds(to:)`, иначе несуществующий метод роняет
    /// всё приложение необработанным исключением Objective-C (см. тот же
    /// приём в SystemTextTranslate).
    static func download(completion: @escaping (String?) -> Void) {
        guard dlopen("/System/Library/Frameworks/Translation.framework/Versions/A/Translation", RTLD_NOW) != nil,
              let raw = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend"),
              let pairAnyClass = objc_getClass("_LTLocalePair"),
              let cls = unsafeBitCast(pairAnyClass, to: AnyClass.self) as? NSObject.Type,
              let translatorAnyClass = objc_getClass("_LTTranslator"),
              let translator = unsafeBitCast(translatorAnyClass, to: AnyClass.self) as? NSObject.Type else {
            completion("Нет системного перевода")
            return
        }
        let initSelector = Selector(("initWithSourceLocale:targetLocale:"))
        let fetchSelector = Selector(("_downloadAssetForLanguagePair:userInitiated:completion:"))
        guard cls.instancesRespond(to: initSelector), translator.instancesRespond(to: fetchSelector) else {
            completion("Нет системного перевода")
            return
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Maker = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject?
        typealias Fetch = @convention(c) (AnyObject, Selector, AnyObject?, Int8, AnyObject?) -> Void
        let getter = unsafeBitCast(raw, to: Getter.self)
        let maker = unsafeBitCast(raw, to: Maker.self)
        let fetch = unsafeBitCast(raw, to: Fetch.self)
        guard let pair = maker(
            getter(cls, sel_registerName("alloc"))!,
            initSelector,
            NSLocale(localeIdentifier: "en_US"),
            NSLocale(localeIdentifier: "ru_RU")
        ) else {
            completion("Не удалось начать загрузку")
            return
        }
        pending = pair
        let done: @convention(block) (AnyObject?) -> Void = { error in
            pending = nil
            pendingDone = nil
            let message = (error as? NSError)?.localizedDescription
            DispatchQueue.main.async {
                completion(message?.isEmpty == false ? message : (error == nil ? nil : "Не удалось скачать"))
            }
        }
        let boxed = unsafeBitCast(done, to: AnyObject.self)
        pendingDone = boxed
        fetch(
            translator,
            sel_registerName("_downloadAssetForLanguagePair:userInitiated:completion:"),
            pair,
            1,
            boxed
        )
    }

    /// Есть непустой файл, в пути которого виден этот язык.
    private static func containsPack(in root: URL, marks: [String]) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            let path = url.path.lowercased()
            guard marks.contains(where: { path.contains($0) }) else { continue }
            if packFileIsReal(url) { return true }
        }
        return false
    }

    /// Обычный файл тяжелее 100 КБ или ссылка на такой файл.
    private static func packFileIsReal(_ url: URL) -> Bool {
        if fileIsHeavy(url) { return true }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path != url.path else { return false }
        return fileIsHeavy(resolved)
    }

    private static func fileIsHeavy(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) >= minimumBytes
    }
}

/// Перевод через интернет без ключа и регистрации — последний запасной путь,
/// когда офлайн-модель Apple недоступна (например, из-за региональных
/// ограничений). Текст уходит открытым на mymemory.translated.net;
/// это не приватно, зато работает там, где Apple ничего не даёт скачать.
enum OnlineTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        let pair = toEnglish ? "ru|en" : "en|ru"
        var components = URLComponents(string: "https://api.mymemory.translated.net/get")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "langpair", value: pair)
        ]
        guard let url = components?.url else {
            return .failure(TranslateFailure(message: "Не удалось собрать запрос"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let gate = DispatchSemaphore(value: 0)
        var outcome: Result<String, TranslateFailure> = .failure(TranslateFailure(message: "Нет интернета для перевода"))
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { gate.signal() }
            if let error {
                outcome = .failure(TranslateFailure(message: error.localizedDescription))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseData = json["responseData"] as? [String: Any],
                  let translated = responseData["translatedText"] as? String,
                  !translated.isEmpty else {
                outcome = .failure(TranslateFailure(message: "Сервер перевода не ответил"))
                return
            }
            outcome = .success(decodeEntities(translated))
        }
        task.resume()
        if gate.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            return .failure(TranslateFailure(message: "Не удалось дозвониться до сервера перевода"))
        }
        return outcome
    }

    /// MyMemory отдаёт апостроф и кавычки html-сущностями — разворачиваем нужные.
    private static func decodeEntities(_ text: String) -> String {
        let entities = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        var result = text
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return result
    }
}

/// Запасной путь через «Команды», если системная модель недоступна,
/// а если и «Команды» не помогли (например, офлайн-пакет Apple вообще
/// не скачивается в этом регионе) — перевод через интернет без ключа.
enum ShortcutTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        let system = SystemTextTranslate.translate(trimmed, toEnglish: toEnglish)
        if case .success(let value) = system, !value.isEmpty {
            return .success(value)
        }
        if let value = viaShortcut(trimmed, toEnglish: toEnglish) {
            return .success(value)
        }
        let online = OnlineTranslate.translate(trimmed, toEnglish: toEnglish)
        if case .success(let value) = online, !value.isEmpty {
            return .success(value)
        }
        offerLanguageSettings()
        if case .failure(let error) = online {
            return .failure(error)
        }
        return .failure(TranslateFailure(message: "language"))
    }

    /// Офлайн-перевод через приложение «Команды». nil — не получилось, тогда идём дальше.
    private static func viaShortcut(_ trimmed: String, toEnglish: Bool) -> String? {
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
            guard signedRun.code == 0 else { return nil }
            prepareInstalledShortcut(toEnglish: toEnglish)
            let named = run("/usr/bin/shortcuts", ["run", "Utka Translate", "--input-path", input.path, "--output-path", output.path, "--output-type", "public.utf8-plain-text"])
            let ran = named.code == 0 ? named : run("/usr/bin/shortcuts", ["run", signed.path, "--input-path", input.path, "--output-path", output.path])
            guard ran.code == 0 else {
                offerShortcut(signed)
                return nil
            }
            let value = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        } catch {
            return nil
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

    /// Открывает системные языки, где качается пакет перевода.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Один раз открывает системные языки, где качается пакет перевода.
    private static func offerLanguageSettings() {
        let key = "offeredLanguagePack"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        openLanguageSettings()
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

/// Два окна: слева английский, справа русский. Пишешь в одно — перевод сам падает в другое.
final class TranslatorView: NSView {
    private let englishScroll = NSScrollView()
    private let russianScroll = NSScrollView()
    private let english: NSTextView
    private let russian: NSTextView
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
        english = NSTextView()
        russian = NSTextView()
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
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 12
        scroll.layer?.masksToBounds = true
        scroll.contentView.drawsBackground = false
        scroll.documentView = text
    }

    private func style(_ text: NSTextView) {
        text.font = UtkaChrome.font(13)
        text.textColor = .white
        text.drawsBackground = true
        text.backgroundColor = NSColor(white: 0.045, alpha: 1)
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
        if lower.contains("интернет") || lower.contains("internet") || lower.contains("offline")
            || lower.contains("connection") || lower.contains("дозвониться") || lower.contains("сервер") {
            return "Нет интернета для перевода"
        }
        if lower.contains("language") || lower.contains("locale") || raw.contains("язык") || raw.contains("пакет") || raw.isEmpty {
            return "Языковой пакет ещё не скачан, перевод через интернет тоже не получился"
        }
        return "Не удалось перевести"
    }
}
