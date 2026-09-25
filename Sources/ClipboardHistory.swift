import AppKit

struct ClipItem: Codable, Equatable {
    var id: String
    var text: String
}

/// История скопированного текста. Картинки и файлы сюда не попадают.
final class ClipboardHistory {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let storeURL: URL
    private var lastCount: Int
    private var bypass = false
    private var timer: Timer?

    init(storeURL: URL) {
        self.storeURL = storeURL
        lastCount = NSPasteboard.general.changeCount
        load()
    }

    func startPolling() {
        guard timer == nil else { return }
        captureCurrentIfNeeded()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Кладёт текст обратно в буфер и не записывает это в историю.
    func copyToPasteboard(_ text: String) {
        bypass = true
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastCount = pb.changeCount
        bypass = false
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
        onChange?()
    }

    /// Правило истории: пустое, файл и повтор подряд не добавляются.
    func consider(text: String?, hasFile: Bool) {
        guard !hasFile else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        if items.first?.text == trimmed { return }
        items.insert(ClipItem(id: UUID().uuidString, text: trimmed), at: 0)
        if items.count > 50 {
            items.removeLast(items.count - 50)
        }
        save()
        onChange?()
    }

    private func captureCurrentIfNeeded() {
        let pb = NSPasteboard.general
        let hasFile = pb.types?.contains(.fileURL) == true
        consider(text: pb.string(forType: .string), hasFile: hasFile)
        lastCount = pb.changeCount
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastCount else { return }
        lastCount = count
        if bypass { return }
        let hasFile = pb.types?.contains(.fileURL) == true
        consider(text: pb.string(forType: .string), hasFile: hasFile)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        items = (try? JSONDecoder().decode([ClipItem].self, from: data)) ?? []
        if items.count > 50 { items = Array(items.prefix(50)) }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// Список истории буфера.
final class ClipboardView: NSView {
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let empty = UtkaChrome.label("Пока пусто", size: 13, color: UtkaChrome.dim)
    private var rows: [TextRowView] = []
    private let history: ClipboardHistory

    init(history: ClipboardHistory) {
        self.history = history
        super.init(frame: .zero)
        wantsLayer = true
        let clip = FlippedClipView()
        scroll.contentView = clip
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        empty.alignment = .center
        addSubview(scroll)
        addSubview(empty)
        history.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scroll.frame = bounds
        empty.frame = bounds
        layoutRows()
    }

    private func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }
        rows = history.items.map { item in
            let row = TextRowView()
            row.show(title: oneLine(item.text), detail: "")
            row.toolTip = item.text
            row.onClick = { [weak self] in self?.history.copyToPasteboard(item.text) }
            row.onDelete = { [weak self] in self?.history.remove(id: item.id) }
            document.addSubview(row)
            return row
        }
        empty.isHidden = !rows.isEmpty
        layoutRows()
    }

    private func layoutRows() {
        let width = max(scroll.contentView.bounds.width, bounds.width)
        var y: CGFloat = 0
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: 40)
            y += 46
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentView.bounds.height))
    }
}
