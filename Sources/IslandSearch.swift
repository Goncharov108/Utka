import AppKit
import Darwin

/// Одна строка поиска: программа, файл, счёт, определение или сеть.
struct IslandHit {
    var title: String
    var detail: String
    var url: URL?
    var copy: String?
}

/// Поиск: программы с диска сразу, индекс Мака по мере нахождения, запасной обход трёх папок.
/// Command+пробел системы не занимает.
final class IslandSearch: NSObject {
    var onHits: (([IslandHit]) -> Void)?

    private let query = NSMetadataQuery()
    private let queryQueue = OperationQueue()
    private var ticket = 0
    private var queryTicket = 0
    private var queryText = ""
    private var pinned: [IslandHit] = []
    private var catalogHits: [IslandHit] = []
    private var nearbyHits: [IslandHit] = []
    private var indexHits: [IslandHit] = []
    private var apps: [(name: String, path: String)] = []
    private var wait: DispatchWorkItem?
    private var deepWalk: DispatchWorkItem?
    private var lastIndexPublish = Date.distantPast

    override init() {
        super.init()
        queryQueue.maxConcurrentOperationCount = 1
        queryQueue.qualityOfService = .userInitiated
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.operationQueue = queryQueue
        query.notificationBatchingInterval = 0.2
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = IslandSearch.readApps()
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = loaded
                guard !self.queryText.isEmpty else { return }
                self.catalogHits = self.matchedApps(self.queryText)
                self.publish()
            }
        }
    }

    /// Счёт и единицы без диска. Нужен самопроверке.
    func preview(_ text: String) -> [IslandHit] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return immediateHits(trimmed)
    }

    /// Пустая строка гасит список. Программы сразу, индекс и папки — следом.
    func lookup(_ text: String) {
        ticket += 1
        let current = ticket
        wait?.cancel()
        deepWalk?.cancel()
        query.stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        queryText = trimmed
        catalogHits = []
        nearbyHits = []
        indexHits = []
        lastIndexPublish = .distantPast
        guard !trimmed.isEmpty else {
            pinned = []
            onHits?([])
            return
        }
        pinned = immediateHits(trimmed) + [webHit(trimmed)]
        catalogHits = matchedApps(trimmed)
        publish()
        guard trimmed.count >= 2 else { return }
        let roots = IslandSearch.homeRoots()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hits = IslandSearch.names(in: roots, query: trimmed, maxDepth: 0)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ticket == current else { return }
                self.nearbyHits = hits
                self.publish()
            }
        }
        let deep = DispatchWorkItem { [weak self] in
            let hits = IslandSearch.names(in: roots, query: trimmed, maxDepth: 3)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ticket == current else { return }
                self.nearbyHits = hits
                self.publish()
            }
        }
        deepWalk = deep
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.18, execute: deep)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.ticket == current else { return }
            self.queryTicket = current
            let safe = trimmed.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
            self.query.predicate = NSPredicate(format: "kMDItemDisplayName LIKE[cd] %@", "*\(safe)*")
            self.query.start()
        }
        wait = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    /// Собирает уже известные строки и отдаёт их списку.
    private func publish() {
        let found = IslandSearch.deduped(catalogHits + nearbyHits + indexHits)
        onHits?(IslandSearch.ordered(pinned, found, query: queryText))
    }

    /// Программы из памяти. Список диска к этому моменту уже читается отдельно.
    private func matchedApps(_ text: String) -> [IslandHit] {
        IslandSearch.appHits(query: text, apps: apps, recent: IslandSearch.recentApps())
    }

    @objc private func queryFinished() {
        let gathering = query.isGathering
        guard query.resultCount > 0 else { return }
        if gathering, Date().timeIntervalSince(lastIndexPublish) < 0.18 { return }
        let mine = queryTicket
        query.disableUpdates()
        let found = (query.results as? [NSMetadataItem] ?? []).prefix(40).compactMap(hit(from:))
        if gathering {
            query.enableUpdates()
        } else {
            query.stop()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ticket == mine else { return }
            self.lastIndexPublish = Date()
            self.indexHits = found
            self.publish()
        }
    }

    /// Точное имя, потом префикс, потом содержание. Словарь и сеть ниже.
    static func ordered(_ pinned: [IslandHit], _ found: [IslandHit], query: String = "") -> [IslandHit] {
        let math = pinned.filter { $0.detail == "Калькулятор" || $0.detail == "Перевод единиц" }
        let dict = pinned.filter { $0.detail == "Словарь" }
        let web = pinned.filter { $0.detail == "Сеть" }
        let rows = deduped(found)
        let exact = rows.filter { rank(of: $0.title, query: query) == 3 }
        let prefix = rows.filter { rank(of: $0.title, query: query) == 2 }
        let contains = rows.filter { rank(of: $0.title, query: query) == 1 }
        let fuzzyApps = rows.filter { $0.detail == "Программа" && rank(of: $0.title, query: query) == 0 }
        let rest = rows.filter { $0.detail != "Программа" && rank(of: $0.title, query: query) == 0 }
        return Array(deduped(math + exact + prefix + contains + fuzzyApps + dict + rest + web).prefix(8))
    }

    /// 3 — имя целиком, 2 — с начала, 1 — внутри, 0 — неточное или пустой запрос.
    static func rank(of title: String, query: String) -> Int {
        let name = folded(title)
        let needle = folded(query)
        guard !needle.isEmpty else { return 0 }
        if name == needle { return 3 }
        if name.hasPrefix(needle) { return 2 }
        if name.contains(needle) { return 1 }
        return 0
    }

    /// Индекс Spotlight хранит чеки пакетов. В списке они только мешают.
    static func acceptsPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("/receipts/") { return false }
        if lower.hasSuffix(".bom") { return false }
        return true
    }

    /// Одна и та же дорожка не занимает две строки.
    static func deduped(_ hits: [IslandHit]) -> [IslandHit] {
        var seen = Set<String>()
        var out: [IslandHit] = []
        for hit in hits {
            let key = hit.url?.path ?? "\(hit.detail)|\(hit.title)"
            if seen.insert(key).inserted { out.append(hit) }
        }
        return out
    }

    /// Неточный набор: «cht» подходит к ChatGPT, если буквы идут подряд и близко.
    static func score(name: String, query: String) -> Int? {
        let foldedName = folded(name)
        let foldedQuery = folded(query)
        guard !foldedQuery.isEmpty else { return nil }
        if foldedName == foldedQuery { return 1000 }
        if foldedName.hasPrefix(foldedQuery) { return 800 }
        if foldedName.contains(foldedQuery) { return 500 }
        guard foldedQuery.count >= 3 else { return nil }
        var index = foldedName.startIndex
        var first: String.Index?
        var last: String.Index?
        var run = 0
        var bestRun = 0
        var previous: String.Index?
        for character in foldedQuery {
            guard let found = foldedName[index...].firstIndex(of: character) else { return nil }
            if first == nil { first = found }
            last = found
            if let previous, foldedName.distance(from: previous, to: found) == 1 {
                run += 1
                bestRun = max(bestRun, run)
            } else {
                run = 1
            }
            previous = found
            index = foldedName.index(after: found)
        }
        guard let first, let last else { return nil }
        let span = foldedName.distance(from: first, to: last) + 1
        guard span <= foldedQuery.count + 2 else { return nil }
        return 200 + bestRun * 10
    }

    /// Программы по очкам. Недавние чуть выше, но не обгоняют точное имя.
    static func appHits(query: String, apps: [(name: String, path: String)], recent: [String: Double]) -> [IslandHit] {
        let now = Date().timeIntervalSince1970
        let ranked = apps.compactMap { app -> (Int, String, String)? in
            guard var points = score(name: app.name, query: query) else { return nil }
            if let used = recent[app.path] {
                let age = now - used
                if age < 86_400 { points += 80 }
                else if age < 30 * 86_400 { points += 40 }
            }
            return (points, app.name, app.path)
        }.sorted { $0.0 > $1.0 }
        return ranked.prefix(5).map {
            IslandHit(title: $0.1, detail: "Программа", url: URL(fileURLWithPath: $0.2), copy: nil)
        }
    }

    /// Документы, стол и загрузки. Туда не входит весь диск.
    static func homeRoots() -> [URL] {
        let manager = FileManager.default
        return [
            manager.urls(for: .documentDirectory, in: .userDomainMask).first,
            manager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            manager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
    }

    /// Имена в заданных папках. Сначала верхний уровень, глубже — с коротким пределом по времени.
    static func names(in roots: [URL], query: String, limit: Int = 12, maxDepth: Int = 3) -> [IslandHit] {
        let needle = folded(query)
        guard needle.count >= 2 else { return [] }
        let skip: Set<String> = ["node_modules", ".git", "library", "deriveddata", "build", ".build", "pods", ".cursor"]
        let deadline = Date().addingTimeInterval(maxDepth == 0 ? 0.15 : 0.4)
        var hits: [IslandHit] = []
        var visits = 0
        var pending: [(URL, Int)] = roots.map { ($0, 0) }
        var index = 0
        while index < pending.count {
            if hits.count >= limit || visits > 2500 || Date() > deadline { break }
            let (directory, depth) = pending[index]
            index += 1
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in items {
                if hits.count >= limit || visits > 2500 || Date() > deadline { break }
                visits += 1
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                let directoryItem = values?.isDirectory == true
                let base = url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
                if folded(base).contains(needle), acceptsPath(url.path) {
                    let detail = url.pathExtension == "app" ? "Программа" : (directoryItem ? "Папка" : "Файл")
                    hits.append(IslandHit(title: base, detail: detail, url: url, copy: nil))
                }
                if directoryItem, url.pathExtension != "app", depth < maxDepth, !skip.contains(url.lastPathComponent.lowercased()) {
                    pending.append((url, depth + 1))
                }
            }
        }
        return hits.sorted { rank(of: $0.title, query: query) > rank(of: $1.title, query: query) }
    }

    /// Папки с программами. Пакет не раскрываем.
    static func readApps() -> [(name: String, path: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        var found: [(name: String, path: String)] = []
        var seen = Set<String>()
        func collect(_ directory: URL, depth: Int) {
            guard depth < 3 else { return }
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }
            for url in items where !url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension == "app" {
                    guard seen.insert(url.path).inserted else { continue }
                    found.append((appName(url), url.path))
                    continue
                }
                let directoryItem = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if directoryItem { collect(url, depth: depth + 1) }
            }
        }
        for root in roots { collect(root, depth: 0) }
        return found
    }

    /// Имя с диска. Чтение пакета на каждую программу тормозит первый запрос.
    private static func appName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? url.lastPathComponent : name
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static let recentKey = "islandAppUse"

    private static func recentApps() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: recentKey) as? [String: Double] ?? [:]
    }

    /// Запоминает программу, чтобы в следующий раз она была выше.
    private static func rememberApp(_ path: String) {
        var store = recentApps()
        store[path] = Date().timeIntervalSince1970
        if store.count > 40 {
            let keep = store.sorted { $0.value > $1.value }.prefix(40)
            store = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(store, forKey: recentKey)
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
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &directory)
        let detail = app ? "Программа" : (directory.boolValue ? "Папка" : "Файл")
        return IslandHit(title: name, detail: detail, url: URL(fileURLWithPath: path), copy: nil)
    }

    /// Открывает файл или копирует готовый ответ.
    static func open(_ hit: IslandHit) {
        if let copy = hit.copy {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copy, forType: .string)
        }
        guard let url = hit.url else { return }
        if url.pathExtension == "app" {
            rememberApp(url.path)
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
        let next = Array(hits.prefix(8))
        let keep = !next.isEmpty && next.first?.title == self.hits.first?.title
        self.hits = next
        if !keep { picked = 0 }
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
