import AppKit

@_silgen_name("proc_listpidspath")
private func proc_listpidspath(
    _ type: UInt32,
    _ typeinfo: UInt32,
    _ path: UnsafePointer<CChar>?,
    _ pathflags: UInt32,
    _ buffer: UnsafeMutableRawPointer?,
    _ buffersize: Int32
) -> Int32

/// Кто-то кроме утки ещё держит файл открытым. Пока да — стирать и уносить его нельзя.
private enum OpenFile {
    static func othersHold(_ path: String) -> Bool {
        path.withCString { cPath in
            var pids = [pid_t](repeating: 0, count: 64)
            let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
            let written = pids.withUnsafeMutableBytes { raw in
                proc_listpidspath(1, 0, cPath, 2, raw.baseAddress, bytes)
            }
            if written < 0 || written >= bytes { return written != 0 }
            let count = Int(written) / MemoryLayout<pid_t>.size
            let me = getpid()
            return pids.prefix(count).contains { $0 != 0 && $0 != me }
        }
    }
}

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
    private var desktopRetry: Timer?
    private var protectedDesktopNames: Set<String> = []
    private var desktopSeen: [String: (size: Int, at: Date)] = [:]

    init(storeURL: URL) {
        self.storeURL = storeURL
        load()
        loadDesktopKeeps()
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
        if let record = records.first(where: { $0.id == id }), UtkaPaths.ownsShot(record.path) {
            ShotStore.discard(beside: record.path)
            try? FileManager.default.removeItem(atPath: record.path)
        }
        records.removeAll { $0.id == id }
        save()
        onChange?()
    }

    /// Имя снимка, который сейчас тащат на стол: обратный сбор его не трогает.
    func protectDesktopName(_ name: String) {
        guard isScreenshotName(name) else { return }
        guard protectedDesktopNames.insert(name).inserted else { return }
        saveDesktopKeeps()
    }

    /// Драг отменён. Если такого файла на столе нет, имя снова можно забирать.
    func releaseDesktopName(_ name: String) {
        let path = desktopDirectory().appendingPathComponent(name).path
        if FileManager.default.fileExists(atPath: path) { return }
        guard protectedDesktopNames.remove(name) != nil else { return }
        saveDesktopKeeps()
    }

    /// Удачный перенос: карточка уходит сразу, свой снимок стирается, когда получатель его отпустил.
    func consumeDropped(id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let path = record.path
        let name = (path as NSString).lastPathComponent
        records.removeAll { $0.id == id }
        save()
        onChange?()
        guard UtkaPaths.ownsShot(path), FileManager.default.fileExists(atPath: path) else { return }
        knownShots.insert(path)
        deleteShotWhenIdle(path: path, name: name)
    }

    /// Карточка та же, файл на диске уже другой. Превью нужно перечитать.
    func noteFileChanged() {
        onChange?()
    }

    func url(for record: ShelfRecord) -> URL? {
        BookmarkStore.locate(bookmark: record.bookmark, path: record.path, name: record.name)
    }

    /// Новые скриншоты пишутся в папку утки, а не на стол. Удаление карточки стирает файл.
    func startScreenshotWatch() {
        guard watchers.isEmpty else { return }
        let shots = UtkaPaths.shots
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
        for url in imageFiles(in: UtkaPaths.shots) where !knownShots.contains(url.path) {
            knownShots.insert(url.path)
            fresh.append(url)
        }
        var waitForDesktop = false
        for url in imageFiles(in: desktopDirectory()) where isScreenshotName(url.lastPathComponent) && !knownShots.contains(url.path) {
            switch desktopShotReadiness(url) {
            case .leave:
                desktopSeen[url.path] = nil
            case .later:
                waitForDesktop = true
            case .ready:
                desktopSeen[url.path] = nil
                guard let moved = moveIntoShots(url) else { continue }
                knownShots.insert(moved.path)
                fresh.append(moved)
            }
        }
        if waitForDesktop { scheduleDesktopRetry() }
        guard !fresh.isEmpty else { return }
        add(urls: fresh)
    }

    /// Свой перенос на стол не забираем. Чужой снимок забираем, только когда запись уже кончилась.
    private func desktopShotReadiness(_ url: URL) -> DesktopShotReadiness {
        if protectedDesktopNames.contains(url.lastPathComponent) { return .leave }
        let size = fileByteCount(url.path)
        if size <= 0 {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
            return Date().timeIntervalSince(modified) < 2 ? .later : .leave
        }
        let now = Date()
        if let prior = desktopSeen[url.path] {
            if prior.size == size, now.timeIntervalSince(prior.at) >= 0.4 {
                return .ready
            }
            if prior.size != size {
                desktopSeen[url.path] = (size, now)
            }
            return .later
        }
        desktopSeen[url.path] = (size, now)
        return .later
    }

    /// Повторная проверка стола, пока системный снимок ещё дописывается.
    private func scheduleDesktopRetry() {
        guard desktopRetry == nil else { return }
        desktopRetry = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.desktopRetry = nil
            self?.scanShots()
        }
    }

    private func desktopDirectory() -> URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
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
        let dir = UtkaPaths.shots
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

    /// Каталог открывается не на главном потоке: диалог доступа к столу иначе вешает запуск.
    private func watch(_ dir: URL) {
        let path = dir.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = Darwin.open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            DispatchQueue.main.async {
                guard let self else {
                    Darwin.close(fd)
                    return
                }
                self.installWatch(fd: fd)
            }
        }
    }

    private func installWatch(fd: Int32) {
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
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = dir.appendingPathComponent(name)
            guard isImageFile(url: url) else { return nil }
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

    private var keepsURL: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("desktop-keeps.json")
    }

    /// Имена, которые человек сам положил на стол. После перезапуска их не забираем, пока файл там лежит.
    private func loadDesktopKeeps() {
        guard let data = try? Data(contentsOf: keepsURL),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return }
        let root = desktopDirectory().path
        protectedDesktopNames = Set(names.filter { name in
            !name.isEmpty && FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(name))
        })
        if protectedDesktopNames.count != Set(names.filter { !$0.isEmpty }).count {
            saveDesktopKeeps()
        }
    }

    private func saveDesktopKeeps() {
        guard let data = try? JSONEncoder().encode(protectedDesktopNames.sorted()) else { return }
        try? data.write(to: keepsURL, options: .atomic)
    }

    /// Стирает снимок полки только после того, как получатель дропа закрыл и исходник, и копию на столе.
    private func deleteShotWhenIdle(path: String, name: String) {
        let sourceSize = fileByteCount(path)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let started = Date()
            var quietSince: Date?
            while true {
                let held = OpenFile.othersHold(path)
                let incomplete = self?.desktopCopyIncomplete(name: name, sourceSize: sourceSize) ?? false
                let onDesktop = self?.desktopHasFile(name) ?? false
                let busy = held || incomplete
                let now = Date()
                if busy {
                    quietSince = nil
                } else if quietSince == nil {
                    quietSince = now
                }
                let waited = now.timeIntervalSince(started)
                let quiet = quietSince.map { now.timeIntervalSince($0) } ?? 0
                // На столе ждём целый png. В другую папку — пока исходник не отпустят.
                let minWait: TimeInterval = onDesktop ? 0.3 : 1.5
                if !busy && waited >= minWait && quiet >= 0.35 { break }
                if waited > 45 { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard !OpenFile.othersHold(path) else { return }
            if self?.desktopCopyIncomplete(name: name, sourceSize: sourceSize) == true { return }
            self?.deleteOwnedShot(path)
        }
    }

    private func desktopHasFile(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: desktopDirectory().appendingPathComponent(name).path)
    }

    /// Копия на столе уже есть, но ещё короче исходника или без заголовка PNG.
    private func desktopCopyIncomplete(name: String, sourceSize: Int) -> Bool {
        let dest = desktopDirectory().appendingPathComponent(name).path
        guard FileManager.default.fileExists(atPath: dest) else { return false }
        if sourceSize > 0, fileByteCount(dest) < sourceSize { return true }
        guard dest.lowercased().hasSuffix(".png") else { return false }
        return !pngHeader(dest)
    }

    private func deleteOwnedShot(_ path: String) {
        let url = URL(fileURLWithPath: path)
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            guard !OpenFile.othersHold(target.path) else { return }
            ShotStore.discard(beside: target.path)
            try? FileManager.default.removeItem(at: target)
        }
        if error != nil, FileManager.default.fileExists(atPath: path), !OpenFile.othersHold(path) {
            ShotStore.discard(beside: path)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func fileByteCount(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Первые восемь байт настоящего PNG.
    private func pngHeader(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8), data.count == 8 else { return false }
        return data == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// Что делать со снимком, который только что появился на столе.
private enum DesktopShotReadiness {
    case leave
    case later
    case ready
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
            card.onExportBegan = { [weak self] name in self?.model.protectDesktopName(name) }
            card.onExportCancel = { [weak self] name in self?.model.releaseDesktopName(name) }
            card.onConsume = { [weak self] in self?.model.consumeDropped(id: record.id) }
            card.onRemove = { [weak self] in self?.model.remove(id: record.id) }
            if let url = model.url(for: record) {
                card.onEdit = { ShotEditor.open(url: url) }
            }
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
