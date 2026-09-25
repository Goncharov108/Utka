import AppKit

struct TranslateFailure: Error {
    var message: String
}

/// Перевод через приложение «Команды» и системное действие перевода. Без сети и без ключей.
enum ShortcutTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
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
            let named = run("/usr/bin/shortcuts", ["run", "Utka Translate", "--input-path", input.path, "--output-path", output.path])
            let ran = named.code == 0 ? named : run("/usr/bin/shortcuts", ["run", signed.path, "--input-path", input.path, "--output-path", output.path])
            guard ran.code == 0 else {
                offerShortcut(signed)
                return .failure(TranslateFailure(message: ran.err.isEmpty ? ran.out : ran.err))
            }
            let value = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return .failure(TranslateFailure(message: ran.err.isEmpty ? ran.out : ran.err)) }
            return .success(value)
        } catch {
            return .failure(TranslateFailure(message: error.localizedDescription))
        }
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

/// Два поля: слева текст, справа перевод.
final class TranslatorView: NSView {
    private let inputScroll = NSTextView.scrollableTextView()
    private let outputScroll = NSTextView.scrollableTextView()
    private let input: NSTextView
    private let output: NSTextView
    private let direction = NSSegmentedControl(labels: ["На английский", "На русский"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = UtkaChrome.label("", size: 12, color: UtkaChrome.dim)
    private var timer: Timer?
    private var ticket = 0
    private var toEnglish = true

    override init(frame frameRect: NSRect) {
        input = inputScroll.documentView as! NSTextView
        output = outputScroll.documentView as! NSTextView
        super.init(frame: frameRect)
        wantsLayer = true
        style(input, editable: true)
        style(output, editable: false)
        direction.selectedSegment = 0
        direction.target = self
        direction.action = #selector(directionChanged)
        status.maximumNumberOfLines = 2
        addSubview(direction)
        addSubview(inputScroll)
        addSubview(outputScroll)
        addSubview(status)
        NotificationCenter.default.addObserver(self, selector: #selector(inputChanged), name: NSText.didChangeNotification, object: input)
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        direction.frame = NSRect(x: 0, y: bounds.height - 28, width: 240, height: 24)
        status.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        let gap: CGFloat = 8
        let top = bounds.height - 36
        let height = max(40, top - 36)
        let width = (bounds.width - gap) / 2
        inputScroll.frame = NSRect(x: 0, y: 36, width: width, height: height)
        outputScroll.frame = NSRect(x: width + gap, y: 36, width: width, height: height)
    }

    private func style(_ text: NSTextView, editable: Bool) {
        text.font = UtkaChrome.font(13)
        text.textColor = .white
        text.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        text.insertionPointColor = .white
        text.isRichText = false
        text.isEditable = editable
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 6, height: 6)
    }

    @objc private func directionChanged() {
        toEnglish = direction.selectedSegment == 0
        schedule()
    }

    @objc private func inputChanged() {
        schedule()
    }

    private func schedule() {
        ticket += 1
        let current = ticket
        timer?.invalidate()
        let text = input.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output.string = ""
            status.stringValue = ""
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.run(ticket: current, text: text)
        }
    }

    private func run(ticket current: Int, text: String) {
        let english = toEnglish
        status.stringValue = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = ShortcutTranslate.translate(text, toEnglish: english)
            DispatchQueue.main.async { [weak self] in
                guard let view = self, view.ticket == current else { return }
                switch result {
                case .success(let value):
                    view.output.string = value
                    view.status.stringValue = ""
                case .failure(let error):
                    view.output.string = ""
                    view.status.stringValue = Self.message(for: error.message)
                }
            }
        }
    }

    private static func message(for raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("language") || lower.contains("locale") || raw.contains("язык") || raw.contains("пакет") || raw.isEmpty {
            return "Языковой пакет ещё не скачан"
        }
        return "Не удалось перевести"
    }
}
