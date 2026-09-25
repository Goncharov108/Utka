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
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
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

    /// Новые скриншоты после запуска сами садятся на полку.
    func startScreenshotWatch() {
        guard watchSource == nil else { return }
        let dir = screenshotDirectory()
        knownShots = Set(imageFiles(in: dir).map(\.path))
        let fd = Darwin.open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { Darwin.close(fd) }
        }
        source.resume()
        watchSource = source
    }

    private func scheduleScan() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.scanShots()
        }
    }

    private func scanShots() {
        let fresh = imageFiles(in: screenshotDirectory()).filter { !knownShots.contains($0.path) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { knownShots.insert($0.path) }
        add(urls: fresh)
    }

    private func screenshotDirectory() -> URL {
        if let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.screencapture"),
           let location = domain["location"] as? String,
           !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
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
