import AppKit

/// Запись каталога библиотеки. Код раздела сюда не входит.
struct LibraryCard: Equatable {
    let id: String
    let title: String
    let symbol: String
}

/// Строка списка «Разделы»: ядро Утки или поставленный раздел библиотеки.
struct SectionSlot: Equatable {
    let id: String
    let title: String
    let listTitle: String
    let symbol: String
    let core: IslandSection?
}

/// Значок раздела. Пустое имя или неизвестный символ даёт пустую картинку.
func utkaSymbol(_ name: String, point: CGFloat, label: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: label)?
        .withSymbolConfiguration(.init(pointSize: point, weight: .medium))
}

/// Мост к репозиторию библиотеки. Чужой код не читает и не запускает.
enum SectionBoard {
    private static let orderKey = "islandSectionOrder"
    private static let shownKey = "islandSectionShown"
    private static let idPattern = "^[A-Za-z][A-Za-z0-9_-]{0,31}$"
    private static var didLoad = false
    private static var catalogCache: [LibraryCard] = []
    private static var installedCache: [LibraryCard] = []

    /// Каталог `utka-library` рядом с репозиторием Утки. Нет файла — библиотека пустая.
    static func catalogURL() -> URL? {
        let url = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("utka-library")
            .appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Заново читает каталог. Снятые из каталога копии с Мака уходят.
    static func reload() {
        loadFromDisk(notify: true)
    }

    /// Разделы каталога, которые ещё не поставлены.
    static var offers: [LibraryCard] {
        ensure()
        let installed = Set(installedCache.map(\.id))
        return catalogCache.filter { !installed.contains($0.id) }
    }

    /// Сверху вниз: ядро и поставленные разделы.
    static var order: [SectionSlot] {
        get {
            ensure()
            return slots(in: readOrderIDs())
        }
        set { writeOrder(newValue.map(\.id)) }
    }

    /// Раздел виден на полосе. Пустая запись включает все.
    static func isShown(_ id: String) -> Bool {
        ensure()
        guard let shown = readShown() else { return true }
        return shown.contains(id)
    }

    /// Включённые сверху вниз. Хотя бы один остаётся.
    static var visible: [SectionSlot] {
        ensure()
        let shown = order.filter { isShown($0.id) }
        if !shown.isEmpty { return shown }
        return Array(order.prefix(1))
    }

    /// Включает или прячет. Последний включённый не выключается.
    static func setShown(_ id: String, _ on: Bool) {
        ensure()
        guard order.contains(where: { $0.id == id }) else { return }
        var shown = explicitShown()
        if on {
            shown.insert(id)
        } else {
            guard shown.count > 1, shown.contains(id) else { return }
            shown.remove(id)
        }
        writeShown(shown)
    }

    /// Можно ли снять поставленный раздел. Ядро и последний включённый остаются.
    static func canRemove(_ id: String) -> Bool {
        ensure()
        guard IslandSection(slotID: id) == nil else { return false }
        if isShown(id), visible.count <= 1 { return false }
        return true
    }

    /// Кладёт карточку каталога в папку данных. Код из репозитория не копирует.
    static func install(_ id: String) {
        ensure()
        guard let card = catalogCache.first(where: { $0.id == id }) else { return }
        guard IslandSection(slotID: id) == nil else { return }
        guard writeCopy(card) else { return }
        if !installedCache.contains(where: { $0.id == id }) {
            installedCache.append(card)
        }
        var ids = slots(in: readOrderIDs()).map(\.id)
        if !ids.contains(id) { ids.append(id) }
        writeOrder(ids, notify: false)
        var shown = explicitShown()
        shown.insert(id)
        writeShown(shown, notify: false)
        NotificationCenter.default.post(name: IslandSection.orderChanged, object: nil)
    }

    /// Убирает копию с Мака. Раздел снова виден только в библиотеке.
    @discardableResult
    static func remove(_ id: String) -> Bool {
        ensure()
        guard canRemove(id) else { return false }
        deleteCopy(id)
        installedCache.removeAll { $0.id == id }
        let ids = slots(in: readOrderIDs()).map(\.id).filter { $0 != id }
        writeOrder(ids, notify: false)
        var shown = explicitShown()
        shown.remove(id)
        writeShown(shown, notify: false)
        NotificationCenter.default.post(name: IslandSection.orderChanged, object: nil)
        return true
    }

    private static func ensure() {
        if !didLoad { loadFromDisk(notify: false) }
    }

    /// Читает каталог и поставленные копии. Уведомляет полосу, только если набор изменился.
    private static func loadFromDisk(notify: Bool) {
        didLoad = true
        let previousCatalog = catalogCache
        let previousInstalled = installedCache
        let copies = readCopies()
        switch readCatalog() {
        case .missing:
            catalogCache = []
            installedCache = copies.values.sorted { $0.id < $1.id }
        case .cards(let cards):
            for id in copies.keys where !cards.contains(where: { $0.id == id }) {
                deleteCopy(id)
            }
            catalogCache = cards
            let stillThere = readCopies()
            installedCache = cards.filter { stillThere[$0.id] != nil }
        }
        guard notify, previousCatalog != catalogCache || previousInstalled != installedCache else { return }
        NotificationCenter.default.post(name: IslandSection.orderChanged, object: nil)
    }

    private static func knownSlots() -> [SectionSlot] {
        IslandSection.allCases.map(coreSlot) + installedCache.map(librarySlot)
    }

    private static func coreSlot(_ section: IslandSection) -> SectionSlot {
        SectionSlot(
            id: section.slotID,
            title: section.title,
            listTitle: section.listTitle,
            symbol: section.symbol,
            core: section
        )
    }

    private static func librarySlot(_ card: LibraryCard) -> SectionSlot {
        SectionSlot(id: card.id, title: card.title, listTitle: card.title, symbol: card.symbol, core: nil)
    }

    /// Сохраняет порядок пользователя и дописывает недостающие разделы в конец.
    private static func slots(in stored: [String]) -> [SectionSlot] {
        let map = Dictionary(uniqueKeysWithValues: knownSlots().map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [SectionSlot] = []
        for id in stored {
            guard let slot = map[id], seen.insert(id).inserted else { continue }
            result.append(slot)
        }
        for slot in knownSlots() where seen.insert(slot.id).inserted {
            result.append(slot)
        }
        return result
    }

    private static func explicitShown() -> Set<String> {
        if let shown = readShown() { return shown }
        return Set(order.map(\.id))
    }

    private static func readOrderIDs() -> [String] {
        guard let raw = UserDefaults.standard.array(forKey: orderKey) else {
            return IslandSection.allCases.map(\.slotID)
        }
        if let ids = raw as? [String] { return ids }
        if let ints = raw as? [Int] {
            return ints.compactMap { IslandSection(rawValue: $0)?.slotID }
        }
        return IslandSection.allCases.map(\.slotID)
    }

    private static func readShown() -> Set<String>? {
        guard let raw = UserDefaults.standard.array(forKey: shownKey) else { return nil }
        if let ids = raw as? [String] { return Set(ids) }
        if let ints = raw as? [Int] {
            return Set(ints.compactMap { IslandSection(rawValue: $0)?.slotID })
        }
        return nil
    }

    private static func writeOrder(_ ids: [String], notify: Bool = true) {
        let next = slots(in: ids).map(\.id)
        let previous = slots(in: readOrderIDs()).map(\.id)
        guard next != previous else { return }
        UserDefaults.standard.set(next, forKey: orderKey)
        if notify {
            NotificationCenter.default.post(name: IslandSection.orderChanged, object: nil)
        }
    }

    private static func writeShown(_ shown: Set<String>, notify: Bool = true) {
        let next = order.map(\.id).filter { shown.contains($0) }
        if let current = readShown(), current == Set(next) { return }
        if readShown() == nil, Set(next) == Set(order.map(\.id)) { return }
        UserDefaults.standard.set(next, forKey: shownKey)
        if notify {
            NotificationCenter.default.post(name: IslandSection.orderChanged, object: nil)
        }
    }

    private enum CatalogRead {
        case missing
        case cards([LibraryCard])
    }

    /// Пустой массив — каталог есть, разделов нет. Битый файл каталог не затирает.
    private static func readCatalog() -> CatalogRead {
        guard let url = catalogURL(), let data = try? Data(contentsOf: url) else { return .missing }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return .missing }
        var seen = Set<String>()
        var cards: [LibraryCard] = []
        for item in raw {
            guard let object = item as? [String: Any],
                  let card = parseCard(object),
                  seen.insert(card.id).inserted else { continue }
            cards.append(card)
        }
        return .cards(cards)
    }

    /// Годная карточка: латинский id, подпись и имя значка. id ядра пропускается.
    private static func parseCard(_ object: [String: Any]) -> LibraryCard? {
        guard let id = object["id"] as? String,
              let title = object["title"] as? String,
              let symbol = object["symbol"] as? String else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: idPattern, options: .regularExpression) != nil else { return nil }
        guard IslandSection(slotID: id) == nil else { return nil }
        guard !trimmedTitle.isEmpty, trimmedTitle.count <= 120 else { return nil }
        guard !trimmedSymbol.isEmpty, trimmedSymbol.count <= 80, !trimmedSymbol.contains("/") else { return nil }
        return LibraryCard(id: id, title: trimmedTitle, symbol: trimmedSymbol)
    }

    private static func copiesRoot() -> URL {
        UtkaPaths.support.appendingPathComponent("Sections", isDirectory: true)
    }

    private static func readCopies() -> [String: LibraryCard] {
        let root = copiesRoot()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [:] }
        var copies: [String: LibraryCard] = [:]
        for name in names {
            let file = root.appendingPathComponent(name).appendingPathComponent("section.json")
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let card = parseCard(object),
                  card.id == name else { continue }
            copies[card.id] = card
        }
        return copies
    }

    private static func writeCopy(_ card: LibraryCard) -> Bool {
        let folder = copiesRoot().appendingPathComponent(card.id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let object: [String: String] = ["id": card.id, "title": card.title, "symbol": card.symbol]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("section.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func deleteCopy(_ id: String) {
        let folder = copiesRoot().appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Тихая карточка поставленного раздела: подпись и одна строка о подключении.
final class LibrarySectionBody: NSView {
    private let titleLabel: NSTextField
    private let note = UtkaChrome.label("Раздел подключён", size: 13, color: UtkaChrome.dim)
    private var lookObserver: NSObjectProtocol?

    init(title: String) {
        titleLabel = UtkaChrome.label(title, size: 15, weight: .medium)
        super.init(frame: .zero)
        titleLabel.alignment = .center
        note.alignment = .center
        addSubview(titleLabel)
        addSubview(note)
        applyLook()
        lookObserver = NotificationCenter.default.addObserver(
            forName: IslandLook.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyLook()
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let lookObserver {
            NotificationCenter.default.removeObserver(lookObserver)
        }
    }

    /// Меняет подпись, если карточка каталога обновилась.
    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// Подтягивает цвета под текущую тему.
    func applyLook() {
        titleLabel.textColor = UtkaChrome.ink
        note.textColor = UtkaChrome.dim
    }

    override func layout() {
        super.layout()
        let block: CGFloat = 44
        let top = (bounds.height - block) / 2
        titleLabel.frame = NSRect(x: 12, y: top + 24, width: max(24, bounds.width - 24), height: 20)
        note.frame = NSRect(x: 12, y: top, width: max(24, bounds.width - 24), height: 18)
    }
}
