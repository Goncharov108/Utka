import AppKit
import Darwin

/// Одна строка поиска: программа, файл, счёт, определение или сеть.
struct IslandHit {
    var title: String
    var detail: String
    var url: URL?
    var copy: String?
}

/// Поиск как у Spotlight: индекс Мака, программы, счёт, словарь и сеть.
/// Command+пробел системы не занимает.
final class IslandSearch: NSObject {
    var onHits: (([IslandHit]) -> Void)?

    private let query = NSMetadataQuery()
    private let queryQueue = OperationQueue()
    private var ticket = 0
    private var queryTicket = 0
    private var pinned: [IslandHit] = []
    private var wait: DispatchWorkItem?

    override init() {
        super.init()
        queryQueue.maxConcurrentOperationCount = 1
        queryQueue.qualityOfService = .userInitiated
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.operationQueue = queryQueue
        query.notificationBatchingInterval = 0.15
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryFinished),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryFinished),
            name: .NSMetadataQueryGatheringProgress,
            object: query
        )
    }

    /// Счёт и единицы без диска. Нужен самопроверке.
    func preview(_ text: String) -> [IslandHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return immediateHits(trimmed)
    }

    /// Пустая строка гасит список. Счёт сразу, индекс — после короткой паузы.
    func lookup(_ text: String) {
        ticket += 1
        let current = ticket
        wait?.cancel()
        query.stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pinned = []
            onHits?([])
            return
        }
        pinned = immediateHits(trimmed)
        onHits?(pinned + [webHit(trimmed)])
        guard trimmed.count >= 2 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.ticket == current else { return }
            self.queryTicket = current
            self.query.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(trimmed)*")
            self.query.start()
        }
        wait = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
    }

    @objc private func queryFinished() {
        guard query.resultCount > 0 else { return }
        if query.resultCount < 24, query.isGathering { return }
        let mine = queryTicket
        query.disableUpdates()
        let found = (query.results as? [NSMetadataItem] ?? []).prefix(24).compactMap(hit(from:))
        query.stop()
        let apps = found.filter { $0.detail == "Программа" }
        let files = found.filter { $0.detail != "Программа" }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ticket == mine else { return }
            self.onHits?(IslandSearch.ordered(self.pinned, apps + files))
        }
    }

    /// Счёт сверху, программа выше словаря, сеть внизу. Чеки установщика не попадают в список.
    static func ordered(_ pinned: [IslandHit], _ found: [IslandHit]) -> [IslandHit] {
        let math = pinned.filter { $0.detail == "Калькулятор" || $0.detail == "Перевод единиц" }
        let apps = found.filter { $0.detail == "Программа" }
        let dict = pinned.filter { $0.detail == "Словарь" }
        let files = found.filter { $0.detail == "Файл" }
        let web = pinned.filter { $0.detail == "Сеть" }
        return Array((math + apps + dict + files + web).prefix(8))
    }

    /// Индекс Spotlight хранит чеки пакетов. В списке они только мешают.
    static func acceptsPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/receipts/") { return false }
        if lower.hasSuffix(".bom") { return false }
        return true
    }

    /// Счёт, перевод единиц и определение — без индекса.
    private func immediateHits(_ text: String) -> [IslandHit] {
        var hits: [IslandHit] = []
        if let value = calculated(text) {
            hits.append(IslandHit(title: value, detail: "Калькулятор", url: nil, copy: value))
        }
        if let converted = converted(text) {
            hits.append(IslandHit(title: converted, detail: "Перевод единиц", url: nil, copy: converted))
        }
        if let meaning = definition(text) {
            hits.append(IslandHit(title: meaning, detail: "Словарь", url: nil, copy: meaning))
        }
        return hits
    }

    private func webHit(_ text: String) -> IslandHit {
        var parts = URLComponents(string: "https://www.google.com/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: text)]
        return IslandHit(title: "Искать «\(text)» в интернете", detail: "Сеть", url: parts?.url, copy: nil)
    }

    private func hit(from item: NSMetadataItem) -> IslandHit? {
        guard let name = item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String,
              let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
              IslandSearch.acceptsPath(path) else { return nil }
        let tree = item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []
        let app = tree.contains("public.application") || path.hasSuffix(".app")
        return IslandHit(title: name, detail: app ? "Программа" : "Файл", url: URL(fileURLWithPath: path), copy: nil)
    }

    /// Открывает файл или копирует готовый ответ.
    static func open(_ hit: IslandHit) {
        if let copy = hit.copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        }
        guard let url = hit.url else { return }
        if url.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func calculated(_ text: String) -> String? {
        let expr = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: " ", with: "")
        guard expr.range(of: #"^[0-9.+\-*/()]+$"#, options: .regularExpression) != nil,
              expr.contains(where: { "+-*/".contains($0) }) else { return nil }
        let value = NSExpression(format: expr).expressionValue(with: nil, context: nil) as? NSNumber
        guard let value, value.doubleValue.isFinite else { return nil }
        let number = value.doubleValue
        if number.rounded() == number { return String(Int(number)) }
        return String(format: "%g", number)
    }

    private func converted(_ text: String) -> String? {
        let pattern = #"^([0-9]+(?:[.,][0-9]+)?)\s*([^\s]+)\s+(?:to|в)\s+([^\s]+)$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 4, let amount = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
        if let from = unit(parts[1]) as? UnitLength, let to = unit(parts[3]) as? UnitLength {
            return format(amount, from, to)
        }
        if let from = unit(parts[1]) as? UnitMass, let to = unit(parts[3]) as? UnitMass {
            return format(amount, from, to)
        }
        if let from = unit(parts[1]) as? UnitTemperature, let to = unit(parts[3]) as? UnitTemperature {
            return format(amount, from, to)
        }
        return nil
    }

    /// Одно и то же измерение в другую единицу.
    private func format<U: Dimension>(_ amount: Double, _ from: U, _ to: U) -> String {
        let value = Measurement(value: amount, unit: from).converted(to: to).value
        return String(format: "%g %@", value, to.symbol)
    }

    private func unit(_ name: String) -> Dimension? {
        switch name.lowercased() {
        case "км", "km": return UnitLength.kilometers
        case "м", "m": return UnitLength.meters
        case "см", "cm": return UnitLength.centimeters
        case "мм", "mm": return UnitLength.millimeters
        case "кг", "kg": return UnitMass.kilograms
        case "г", "g": return UnitMass.grams
        case "°c", "celsius", "ц": return UnitTemperature.celsius
        case "°f", "fahrenheit": return UnitTemperature.fahrenheit
        default: return nil
        }
    }

    /// Определение из словаря Мака, если он есть.
    private func definition(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.contains(where: { $0.isWhitespace }), word.count > 1 else { return nil }
        guard let handle = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY),
              let symbol = dlsym(handle, "DCSCopyTextDefinition") else { return nil }
        typealias Copy = @convention(c) (UnsafeRawPointer?, CFString, CFRange) -> Unmanaged<CFString>?
        let copy = unsafeBitCast(symbol, to: Copy.self)
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let value = copy(nil, word as CFString, range)?.takeRetainedValue() else { return nil }
        let line = (value as String).replacingOccurrences(of: "\n", with: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}

/// Список под полем. Тёмный, системный гротеск.
final class SearchDrop: NSView {
    var onPick: ((IslandHit) -> Void)?
    private var hits: [IslandHit] = []
    private var rows: [NSButton] = []
    private var picked = 0

    /// Сколько места занимает текущий список.
    var neededHeight: CGFloat { hits.isEmpty ? 0 : CGFloat(hits.count) * 32 + 8 }

    func show(_ hits: [IslandHit]) {
        self.hits = Array(hits.prefix(8))
        picked = 0
        isHidden = self.hits.isEmpty
        rebuild()
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        let last = max(0, visibleCount() - 1)
        picked = min(last, max(0, picked + delta))
        paint()
    }

    /// Сколько строк помещается, не залезая на поле поиска.
    private func visibleCount() -> Int {
        let room = Int((bounds.height - 8) / 32)
        if room < 1 { return hits.count }
        return min(hits.count, room)
    }

    func current() -> IslandHit? {
        guard hits.indices.contains(picked) else { return nil }
        return hits[picked]
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = hits.enumerated().map { index, hit in
            let button = NSButton()
            button.isBordered = false
            button.tag = index
            button.target = self
            button.action = #selector(clicked(_:))
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            addSubview(button)
            return button
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        paint()
    }

    private func paint() {
        let width = bounds.width
        for (index, button) in rows.enumerated() {
            let hit = hits[index]
            let on = index == picked
            button.frame = NSRect(x: 4, y: bounds.height - CGFloat(index + 1) * 32, width: max(40, width - 8), height: 30)
            button.attributedTitle = NSAttributedString(
                string: "\(hit.title)  \(hit.detail)",
                attributes: [
                    .font: UtkaChrome.font(12, weight: on ? .semibold : .regular),
                    .foregroundColor: on ? UtkaChrome.ink : UtkaChrome.dim
                ]
            )
        }
    }

    override func layout() {
        super.layout()
        paint()
    }

    @objc private func clicked(_ sender: NSButton) {
        guard hits.indices.contains(sender.tag) else { return }
        onPick?(hits[sender.tag])
    }
}
