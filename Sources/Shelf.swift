import AppKit

struct ShelfRecord: Codable, Equatable {
    var id: String
    var name: String
    var bookmark: String
    var path: String
}

/// Временная полка файлов и свежих скриншотов.
final class ShelfModel {
    private(set) var records: [ShelfRecord] = []
    var onChange: (() -> Void)?

    private let storeURL: URL
    private var watchers: [(source: DispatchSourceFileSystemObject, fd: Int32)] = []
    private var knownShots: Set<String> = []
    private var scanTimer: Timer?

    init(storeURL: URL) {
        self.storeURL = storeURL
        load()
    }

    func add(urls: [URL]) {
        var changed = false
        for url in urls {
            let path = url.standardizedFileURL.path
            if records.contains(where: { $0.path == path }) { continue }
            guard let data = BookmarkStore.data(for: url) else { continue }
            records.insert(ShelfRecord(
                id: UUID().uuidString,
                name: url.lastPathComponent,
                bookmark: data.base64EncodedString(),
                path: path
            ), at: 0)
            changed = true
        }
        guard changed else { return }
        save()
        onChange?()
    }

    func remove(id: String) {
        if let record = records.first(where: { $0.id == id }), isOwnedShot(record.path) {
            try? FileManager.default.removeItem(atPath: record.path)
        }
        records.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func url(for record: ShelfRecord) -> URL? {
        if let data = Data(base64Encoded: record.bookmark),
           let url = BookmarkStore.url(from: data),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let pathURL = URL(fileURLWithPath: record.path)
        if FileManager.default.fileExists(atPath: pathURL.path) { return pathURL }
        return nil
    }

    /// Новые скриншоты пишутся в папку утки, а не на стол. Удаление карточки стирает файл.
    func startScreenshotWatch() {
        guard watchers.isEmpty else { return }
        let shots = shotsDirectory()
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        retargetScreenshotCapture(to: shots)
        relocateDesktopShots()
        knownShots = Set(imageFiles(in: shots).map(\.path))
        watch(shots)
        watch(desktopDirectory())
    }

    private func scheduleScan() {
        scanTimer?.invalidate()
        scanShots()
    }

    private func scanShots() {
        var fresh: [URL] = []
        for url in imageFiles(in: shotsDirectory()) where !knownShots.contains(url.path) {
            knownShots.insert(url.path)
            fresh.append(url)
        }
        for url in imageFiles(in: desktopDirectory()) where isScreenshotName(url.lastPathComponent) && !knownShots.contains(url.path) {
            guard let moved = moveIntoShots(url) else { continue }
            knownShots.insert(moved.path)
            fresh.append(moved)
        }
        guard !fresh.isEmpty else { return }
        add(urls: fresh)
    }

    /// Куда macOS кладёт новые снимки экрана.
    private func shotsDirectory() -> URL {
        UtkaPaths.support.appendingPathComponent("Shots", isDirectory: true)
    }

    private func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private func isOwnedShot(_ path: String) -> Bool {
        let root = shotsDirectory().path
        return path == root || path.hasPrefix(root + "/")
    }

    private func isScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("снимок экрана") || lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot")
    }

    /// Уже лежащие на столе снимки с полки уезжают в папку утки.
    private func relocateDesktopShots() {
        let desktop = desktopDirectory().path
        var changed = false
        for index in records.indices {
            let path = records[index].path
            guard path.hasPrefix(desktop + "/"), isScreenshotName((path as NSString).lastPathComponent) else { continue }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let moved = moveIntoShots(URL(fileURLWithPath: path)) else { continue }
            records[index].path = moved.path
            records[index].name = moved.lastPathComponent
            if let data = BookmarkStore.data(for: moved) {
                records[index].bookmark = data.base64EncodedString()
            }
            changed = true
        }
        guard changed else { return }
        save()
        onChange?()
    }

    private func moveIntoShots(_ url: URL) -> URL? {
        let dir = shotsDirectory()
        if url.path.hasPrefix(dir.path + "/") { return url }
        var dest = dir.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Снимки пишутся в папку утки, без плашки в углу экрана.
    private func retargetScreenshotCapture(to dir: URL) {
        var domain = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture") ?? [:]
        let already = (domain["location"] as? String) == dir.path && (domain["show-thumbnail"] as? Bool) == false
        guard !already else { return }
        domain["location"] = dir.path
        domain["show-thumbnail"] = false
        UserDefaults.standard.setPersistentDomain(domain, forName: "com.apple.screencapture")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["screencaptureui"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    private func watch(_ dir: URL) {
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watchers.append((source, fd))
    }

    private func imageFiles(in dir: URL) -> [URL] {
        let exts: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = dir.appendingPathComponent(name)
            guard exts.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        records = (try? JSONDecoder().decode([ShelfRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// Полка: бросил файл — карточка, утащил — файл уходит и карточка снимается.
final class ShelfView: NSView {
    var onDrag: ((Bool) -> Void)?
    private let model: ShelfModel
    private let scroll = NSScrollView()
    private let document = NSView()
    private let empty = UtkaChrome.label("Пока пусто", size: 13, color: UtkaChrome.dim)
    private var cards: [FileCardView] = []

    init(model: ShelfModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        scroll.documentView = document
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        empty.alignment = .center
        addSubview(scroll)
        addSubview(empty)
        registerForDraggedTypes([.fileURL])
        model.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scroll.frame = bounds
        empty.frame = bounds
        layoutCards()
    }

    private func rebuild() {
        document.subviews.forEach { $0.removeFromSuperview() }
        cards = model.records.map { record in
            let card = FileCardView()
            card.show(url: model.url(for: record), title: record.name)
            card.consumeOnDrop = true
            card.onDrag = { [weak self] active in self?.onDrag?(active) }
            card.onRemove = { [weak self] in self?.model.remove(id: record.id) }
            document.addSubview(card)
            return card
        }
        empty.isHidden = !cards.isEmpty
        layoutCards()
    }

    private func layoutCards() {
        var x: CGFloat = 0
        for card in cards {
            card.frame = NSRect(x: x, y: 8, width: 112, height: 104)
            x += 120
        }
        let height = max(scroll.contentView.bounds.height, 120)
        document.frame = NSRect(x: 0, y: 0, width: max(x, 1), height: height)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        model.add(urls: urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
