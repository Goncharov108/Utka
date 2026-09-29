import AppKit

struct TranslateFailure: Error {
    var message: String
}

/// Единственный путь перевода — свой офлайн-движок (utka-apps/utka-translate).
/// Ни Apple, ни какой-либо сторонний сервис, ни открытие системных настроек
/// здесь больше не задействованы: прошлые попытки использовать приватный
/// API Apple дважды роняли всё приложение целиком, уже после всех проверок
/// снаружи — крах происходил внутри самого закрытого фреймворка Apple,
/// поймать его было нечем. Раз движок не установлен или не смог перевести —
/// об этом просто сообщается, ничего не подстраховывает вызовом наружу.
enum ShortcutTranslate {
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        guard let result = NativeTranslate.translate(trimmed, toEnglish: toEnglish) else {
            return .failure(TranslateFailure(message: "not-installed"))
        }
        return result
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
        if raw == "not-installed" {
            return "Свой переводчик не скачан — откройте настройки утки"
        }
        return "Не удалось перевести"
    }
}
