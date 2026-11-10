import AppKit
import Darwin

/// Константы и раскладки libproc — открытый API, без частного SDK.
private enum PulseProc {
    static let allPids: UInt32 = 1
    static let taskInfo: Int32 = 4
    static let shortBSD: Int32 = 13
    static let maxComLen = 16

    struct TaskInfo {
        var virtualSize: UInt64 = 0
        var residentSize: UInt64 = 0
        var totalUser: UInt64 = 0
        var totalSystem: UInt64 = 0
        var threadsUser: UInt64 = 0
        var threadsSystem: UInt64 = 0
        var policy: Int32 = 0
        var faults: Int32 = 0
        var pageins: Int32 = 0
        var cowFaults: Int32 = 0
        var messagesSent: Int32 = 0
        var messagesReceived: Int32 = 0
        var syscallsMach: Int32 = 0
        var syscallsUnix: Int32 = 0
        var csw: Int32 = 0
        var threadnum: Int32 = 0
        var numrunning: Int32 = 0
        var priority: Int32 = 0
    }

    struct ShortBSD {
        var pid: UInt32 = 0
        var ppid: UInt32 = 0
        var pgid: UInt32 = 0
        var status: UInt32 = 0
        var comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                   CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var flags: UInt32 = 0
        var uid: uid_t = 0
        var gid: gid_t = 0
        var ruid: uid_t = 0
        var rgid: gid_t = 0
        var svuid: uid_t = 0
        var svgid: gid_t = 0
        var rfu: UInt32 = 0
    }

}

@_silgen_name("proc_listpids")
private func pulseListPIDs(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidinfo")
private func pulsePIDInfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pidpath")
private func pulsePIDPath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

@_silgen_name("proc_name")
private func pulseProcName(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

/// Снимок нагрузки Мака для раздела «Пульс».
struct PulseSnapshot {
    var headline: String
    var cpuShare: Double
    var memoryPressure: Double
    var heatTitle: String
    var heatShare: Double
    var apps: [PulseApp]
}

/// Программа (не отдельный процесс): иконка, имя, процессор, память.
struct PulseApp {
    var key: String
    var name: String
    var icon: NSImage
    var cpuPercent: Double
    var memoryBytes: UInt64
    var canQuit: Bool
    var bundleURL: URL?
    var bundleID: String?
    var mainPID: pid_t
}

/// Собирает процессор, давление памяти, нагрев и виновников по программам.
enum PulseReader {
    private static var prevCPU: host_cpu_load_info?
    private static var prevTicks: [pid_t: UInt64] = [:]
    private static var prevStamp: CFAbsoluteTime = 0

    /// Один опрос открытыми вызовами Darwin и AppKit. Без пароля и частных API.
    static func sample() -> PulseSnapshot {
        let cpu = systemCPU()
        let pressure = memoryPressure()
        let heat = heatGauge()
        let apps = topApps()
        let headline: String
        if let top = apps.first, top.cpuPercent >= 25 || top.memoryBytes >= 800 * 1024 * 1024 {
            headline = "Тормозит \(top.name): \(formatCPU(top.cpuPercent)) процессора, \(formatMemory(top.memoryBytes)) памяти"
        } else {
            headline = "Всё спокойно"
        }
        return PulseSnapshot(
            headline: headline,
            cpuShare: cpu,
            memoryPressure: pressure,
            heatTitle: heat.title,
            heatShare: heat.share,
            apps: Array(apps.prefix(5))
        )
    }

    /// Доля занятого процессора всего Мака, 0…1.
    private static func systemCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        defer { prevCPU = info }
        guard let prev = prevCPU else { return 0 }
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(1, max(0, (user + system + nice) / total))
    }

    /// Давление на память 0…1: занятые и сжатые страницы к общему пулу. Не «занято ГБ».
    private static func memoryPressure() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let active = Double(stats.active_count)
        let inactive = Double(stats.inactive_count)
        let wired = Double(stats.wire_count)
        let free = Double(stats.free_count)
        let speculative = Double(stats.speculative_count)
        let compressed = Double(stats.compressor_page_count)
        let total = active + inactive + wired + free + speculative + compressed
        guard total > 0 else { return 0 }
        let heavy = wired + active + compressed
        return min(1, max(0, heavy / total))
    }

    /// Нагрев по ProcessInfo.thermalState.
    private static func heatGauge() -> (title: String, share: Double) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return ("Норма", 0.12)
        case .fair: return ("Тепло", 0.4)
        case .serious: return ("Жарко", 0.72)
        case .critical: return ("Критично", 1)
        @unknown default: return ("—", 0)
        }
    }

    /// Пять программ с наибольшей нагрузкой. Помощники складываются в свою программу.
    private static func topApps() -> [PulseApp] {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(0.4, now - (prevStamp == 0 ? now - 1.5 : prevStamp))
        prevStamp = now

        var bytes = pulseListPIDs(PulseProc.allPids, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.stride)
        bytes = pids.withUnsafeMutableBufferPointer {
            pulseListPIDs(PulseProc.allPids, 0, UnsafeMutableRawPointer($0.baseAddress), bytes)
        }
        guard bytes > 0 else { return [] }
        let live = Array(pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let myUID = getuid()
        var nextTicks: [pid_t: UInt64] = [:]
        var groups: [String: Acc] = [:]

        for pid in live {
            var info = PulseProc.TaskInfo()
            let size = Int32(MemoryLayout<PulseProc.TaskInfo>.stride)
            let got = withUnsafeMutablePointer(to: &info) {
                pulsePIDInfo(pid, PulseProc.taskInfo, 0, UnsafeMutableRawPointer($0), size)
            }
            guard got == size else { continue }

            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let pathLen = pathBuf.withUnsafeMutableBufferPointer {
                pulsePIDPath(pid, UnsafeMutableRawPointer($0.baseAddress), UInt32(MAXPATHLEN))
            }
            let path = pathLen > 0 ? String(cString: pathBuf) : ""

            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nameCap = UInt32(nameBuf.count)
            let nameLen = nameBuf.withUnsafeMutableBufferPointer {
                pulseProcName(pid, UnsafeMutableRawPointer($0.baseAddress), nameCap)
            }
            let rawName = nameLen > 0 ? String(cString: nameBuf) : URL(fileURLWithPath: path).lastPathComponent
            guard !rawName.isEmpty else { continue }

            let ticks = info.totalUser &+ info.totalSystem
            nextTicks[pid] = ticks
            let prev = prevTicks[pid] ?? ticks
            let delta = ticks &- prev
            // totalUser/totalSystem — наносекунды на современных macOS.
            let cpuPercent = (Double(delta) / 1_000_000_000.0) / dt * 100.0
            let mem = info.residentSize

            let app = NSRunningApplication(processIdentifier: pid)
            let key = groupKey(rawName: rawName, path: path, app: app)
            let host = hostApp(path: path, app: app)
            let display = friendlyName(rawName: rawName, path: path, app: host ?? app)
            let icon = friendlyIcon(path: path, app: host ?? app)
            var row = groups[key] ?? Acc(
                key: key,
                name: display,
                icon: icon,
                cpu: 0,
                memory: 0,
                canQuit: false,
                bundleURL: host?.bundleURL ?? app?.bundleURL,
                bundleID: host?.bundleIdentifier ?? app?.bundleIdentifier,
                mainPID: pid,
                bestCPU: -1
            )
            row.cpu += max(0, cpuPercent)
            row.memory += mem
            if row.name == "Программа" || row.name.count > display.count {
                row.name = display
            }
            if isColimaFamily(rawName: rawName, path: path) {
                row.name = "Colima"
                row.icon = icon
            } else if let host, host.activationPolicy == .regular {
                row.name = friendlyName(rawName: rawName, path: path, app: host)
                row.icon = host.icon ?? row.icon
                row.bundleURL = host.bundleURL ?? row.bundleURL
                row.bundleID = host.bundleIdentifier ?? row.bundleID
                row.mainPID = host.processIdentifier
                row.bestCPU = max(row.bestCPU, cpuPercent)
            } else if cpuPercent >= row.bestCPU {
                row.bestCPU = cpuPercent
                row.mainPID = pid
            }
            groups[key] = row
        }

        prevTicks = nextTicks

        let selfBundle = Bundle.main.bundleIdentifier
        for key in groups.keys {
            guard var row = groups[key] else { continue }
            let host = row.bundleID.flatMap { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                    $0.activationPolicy == .regular
                }
            } ?? NSRunningApplication(processIdentifier: row.mainPID)
            if isColimaFamily(rawName: row.name, path: "") || row.key == "name:colima" {
                row.name = "Colima"
            } else if let host, host.activationPolicy == .regular {
                row.name = friendlyName(rawName: row.name, path: host.bundleURL?.path ?? "", app: host)
                row.icon = host.icon ?? row.icon
                row.bundleURL = host.bundleURL ?? row.bundleURL
                row.bundleID = host.bundleIdentifier ?? row.bundleID
                row.mainPID = host.processIdentifier
            }
            let uid = processUID(row.mainPID)
            let otherUser = uid != nil && uid != myUID
            let isSelf = row.mainPID == myPID
                || (row.bundleID != nil && row.bundleID == selfBundle)
                || (host?.bundleIdentifier == selfBundle)
            let isUserApp = host?.activationPolicy == .regular
            row.canQuit = isUserApp && !isSelf && !otherUser && host != nil
            groups[key] = row
        }

        return groups.values
            .map {
                PulseApp(
                    key: $0.key,
                    name: $0.name,
                    icon: $0.icon,
                    cpuPercent: $0.cpu,
                    memoryBytes: $0.memory,
                    canQuit: $0.canQuit,
                    bundleURL: $0.bundleURL,
                    bundleID: $0.bundleID,
                    mainPID: $0.mainPID
                )
            }
            .sorted {
                if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
                return $0.memoryBytes > $1.memoryBytes
            }
    }

    /// Имя программы без хвостов Helper / Renderer.
    private static func programName(rawName: String, app: NSRunningApplication?) -> String {
        if let name = app?.localizedName, !name.isEmpty { return name }
        return cleanHelperName(rawName)
    }

    /// Ключ группировки: сначала .app на диске, чтобы помощники сложились в программу.
    private static func groupKey(rawName: String, path: String, app: NSRunningApplication?) -> String {
        if isColimaFamily(rawName: rawName, path: path) {
            return "name:colima"
        }
        if let bundle = bundlePath(from: path) {
            return "path:" + bundle
        }
        if let host = hostApp(path: path, app: app), let url = host.bundleURL {
            return "path:" + url.path
        }
        if let id = app?.bundleIdentifier, !id.isEmpty, app?.activationPolicy == .regular {
            return "id:" + id
        }
        if let url = app?.bundleURL {
            return "bundle:" + url.path
        }
        return "name:" + cleanHelperName(rawName).lowercased()
    }

    /// Colima тянет limactl и системную ВМ Apple — это одна «программа» для Пульса.
    private static func isColimaFamily(rawName: String, path: String) -> Bool {
        let base = rawName.lowercased()
        if base == "colima" || base == "limactl" { return true }
        if path.contains("/colima/") || path.contains("/.colima/") || path.contains("/Cellar/colima/") {
            return true
        }
        if path.contains("/Cellar/lima/") || path.hasSuffix("/limactl") { return true }
        if path.contains("Virtualization.VirtualMachine") { return true }
        return false
    }

    /// Человеческое имя: без битой локали XPC и без «для приложения …».
    private static func friendlyName(rawName: String, path: String, app: NSRunningApplication?) -> String {
        if isColimaFamily(rawName: rawName, path: path) { return "Colima" }
        if let app, app.activationPolicy == .regular, let name = app.localizedName, isCleanLabel(name) {
            return sanitizeName(name)
        }
        let pathName = URL(fileURLWithPath: path).lastPathComponent
        if !pathName.isEmpty, pathName != "/", isCleanLabel(pathName) {
            return sanitizeName(pathName)
        }
        if let tip = quotedAppTip(app?.localizedName ?? "") {
            return sanitizeName(tip)
        }
        let cleaned = sanitizeName(programName(rawName: rawName, app: app))
        if cleaned != "Программа", isCleanLabel(cleaned) { return cleaned }
        if !pathName.isEmpty, pathName != "/" { return sanitizeName(pathName) }
        return "Программа"
    }

    /// Иконка: для Colima — brew-бинарник, иначе программа или путь.
    private static func friendlyIcon(path: String, app: NSRunningApplication?) -> NSImage {
        if isColimaFamily(rawName: "", path: path) {
            let colima = "/usr/local/bin/colima"
            if FileManager.default.fileExists(atPath: colima) {
                return NSWorkspace.shared.icon(forFile: colima)
            }
        }
        if let app, let icon = app.icon { return icon }
        if let bundle = bundlePath(from: path) {
            return NSWorkspace.shared.icon(forFile: bundle)
        }
        if !path.isEmpty {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(forFile: "/bin/ps")
    }

    /// Имя без кракозябр и канцелярита «для приложения».
    private static func isCleanLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.localizedCaseInsensitiveContains("для приложения") { return false }
        if trimmed.localizedCaseInsensitiveContains("for application") { return false }
        let clean = sanitizeName(trimmed)
        guard !clean.isEmpty, clean != "Программа" else { return false }
        let originalLetters = trimmed.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        let kept = clean.unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.count
        guard originalLetters > 0 else { return false }
        return Double(kept) / Double(originalLetters) >= 0.8
    }

    /// Достаёт «limactl» из подписи службы ВМ.
    private static func quotedAppTip(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"«([^»]+)»"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let tipRange = Range(match.range(at: 1), in: text) else { return nil }
        let tip = String(text[tipRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return tip.isEmpty ? nil : tip
    }

    /// Главная программа по пути внутри .app или по bundle.
    private static func hostApp(path: String, app: NSRunningApplication?) -> NSRunningApplication? {
        if let app, app.activationPolicy == .regular { return app }
        if let bundle = bundlePath(from: path) {
            let url = URL(fileURLWithPath: bundle)
            if let id = Bundle(url: url)?.bundleIdentifier {
                if let regular = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                    $0.activationPolicy == .regular
                }) {
                    return regular
                }
            }
            return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == bundle }
        }
        if let id = app?.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                $0.activationPolicy == .regular
            } ?? app
        }
        return app
    }

    /// Корень .app из пути процесса.
    private static func bundlePath(from path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? path.range(of: ".app") else { return nil }
        let root = String(path[..<range.lowerBound]) + ".app"
        return root
    }

    /// Убирает служебные хвосты помощников, в том числе «Helper (fileWatcher)».
    private static func cleanHelperName(_ raw: String) -> String {
        var name = raw
        if let regex = try? NSRegularExpression(pattern: #" Helper( \([^)]*\))?$"#) {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            name = regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
        }
        let tails = [" (Renderer)", " (GPU)", " (Plugin)", " (Alerts)"]
        for tail in tails where name.hasSuffix(tail) {
            name = String(name.dropLast(tail.count))
            break
        }
        return name.isEmpty ? raw : name
    }

    /// Латиница, кириллица, цифры и простые знаки — без битой кодировки из proc_name.
    private static func sanitizeName(_ raw: String) -> String {
        let text = String(raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            let latin = (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            let cyrillic = (v >= 0x0400 && v <= 0x04FF)
            let digit = v >= 48 && v <= 57
            let space = v == 32
            let mark = "-._()[]".unicodeScalars.contains(scalar)
            return latin || cyrillic || digit || space || mark
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Программа" : text
    }

    static func formatCPU(_ value: Double) -> String {
        if value >= 10 {
            return String(format: "%.0f%%", value)
        }
        return String(format: "%.1f%%", value).replacingOccurrences(of: ".", with: ",")
    }

    static func formatMemory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 {
            return String(format: "%.1f ГБ", gb).replacingOccurrences(of: ".", with: ",")
        }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f МБ", mb)
    }

    /// UID процесса через короткий BSD-снимок.
    private static func processUID(_ pid: pid_t) -> uid_t? {
        var info = PulseProc.ShortBSD()
        let size = Int32(MemoryLayout<PulseProc.ShortBSD>.stride)
        let got = withUnsafeMutablePointer(to: &info) {
            pulsePIDInfo(pid, PulseProc.shortBSD, 0, UnsafeMutableRawPointer($0), size)
        }
        guard got == size else { return nil }
        return info.uid
    }

    private struct Acc {
        var key: String
        var name: String
        var icon: NSImage
        var cpu: Double
        var memory: UInt64
        var canQuit: Bool
        var bundleURL: URL?
        var bundleID: String?
        var mainPID: pid_t
        var bestCPU: Double
    }
}

/// Тело раздела «Пульс» на островке.
final class PulseIslandView: NSView {
    private let headline = UtkaChrome.label("Считаю…", size: 14, weight: .medium)
    private let gauges = PulseGaugesView()
    private let list = FlippedView()
    private var rows: [PulseAppRow] = []
    private var timer: Timer?
    private var lookObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol? = nil
    private var quitPrompt: PulseQuitPrompt?
    private var lastApps: [PulseApp] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        headline.maximumNumberOfLines = 2
        headline.cell?.wraps = true
        headline.cell?.truncatesLastVisibleLine = true
        addSubview(headline)
        addSubview(gauges)
        addSubview(list)
        for _ in 0..<5 {
            let row = PulseAppRow()
            row.onQuit = { [weak self] key in self?.askQuit(key) }
            list.addSubview(row)
            rows.append(row)
        }
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
        stopSampling()
        if let lookObserver {
            NotificationCenter.default.removeObserver(lookObserver)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    /// Цвета под тему островка.
    func applyLook() {
        headline.textColor = UtkaChrome.ink
        headline.font = UtkaChrome.font(14, weight: .medium)
        gauges.applyLook()
        rows.forEach { $0.applyLook() }
    }

    /// Включает опрос, когда раздел на экране.
    func setActive(_ on: Bool) {
        if on {
            startSampling()
        } else {
            stopSampling()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token = windowObserver {
            NotificationCenter.default.removeObserver(token)
            windowObserver = nil
        }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.syncSampling()
            }
        }
        syncSampling()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        syncSampling()
    }

    override func layout() {
        super.layout()
        layoutPulse()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPulse()
    }

    /// Верх — виновник, середина — спидометры, низ — пять строк.
    private func layoutPulse() {
        let pad: CGFloat = 8
        let width = max(40, bounds.width - pad * 2)
        let headH: CGFloat = 36
        headline.frame = NSRect(x: pad, y: bounds.height - headH - 2, width: width, height: headH)
        let gaugeH: CGFloat = 78
        gauges.frame = NSRect(x: pad, y: headline.frame.minY - gaugeH - 4, width: width, height: gaugeH)
        let listTop = gauges.frame.minY - 6
        list.frame = NSRect(x: pad, y: 0, width: width, height: max(0, listTop))
        let rowH: CGFloat = min(32, list.bounds.height / 5)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * rowH, width: list.bounds.width, height: rowH)
        }
    }

    /// Опрос только пока раздел открыт и островок виден.
    private func syncSampling() {
        let visible = superview != nil && window?.isVisible == true
        if visible {
            startSampling()
        } else {
            stopSampling()
        }
    }

    private func startSampling() {
        guard timer == nil else {
            refresh()
            return
        }
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard superview != nil, window?.isVisible == true else {
            stopSampling()
            return
        }
        let shot = PulseReader.sample()
        headline.stringValue = shot.headline
        gauges.update(
            cpu: shot.cpuShare,
            memory: shot.memoryPressure,
            heat: shot.heatShare,
            heatTitle: shot.heatTitle
        )
        lastApps = shot.apps
        for (index, row) in rows.enumerated() {
            if index < shot.apps.count {
                row.isHidden = false
                row.show(shot.apps[index])
            } else {
                row.isHidden = true
            }
        }
    }

    /// Короткий вопрос, затем вежливое завершение.
    private func askQuit(_ key: String) {
        guard quitPrompt == nil else { return }
        guard let app = lastApps.first(where: { $0.key == key }), app.canQuit else { return }
        let prompt = PulseQuitPrompt(text: "Закрыть «\(app.name)»?")
        quitPrompt = prompt
        prompt.onChoose = { [weak self] ok in
            self?.quitPrompt = nil
            guard ok else { return }
            self?.quitGracefully(app)
        }
        prompt.show(over: window)
    }

    /// Вежливое завершение программы пользователя. Без forceQuit.
    private func quitGracefully(_ app: PulseApp) {
        if let id = app.bundleID,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
               $0.activationPolicy == .regular
           }) {
            running.terminate()
            return
        }
        if let running = NSRunningApplication(processIdentifier: app.mainPID) {
            running.terminate()
        }
    }
}

/// Три спидометра: процессор, давление памяти, нагрев.
private final class PulseGaugesView: NSView {
    private let cpu = PulseDialView(title: "Процессор")
    private let memory = PulseDialView(title: "Память")
    private let heat = PulseDialView(title: "Нагрев")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(cpu)
        addSubview(memory)
        addSubview(heat)
    }

    required init?(coder: NSCoder) { nil }

    func applyLook() {
        cpu.applyLook()
        memory.applyLook()
        heat.applyLook()
    }

    func update(cpu share: Double, memory pressure: Double, heat value: Double, heatTitle: String) {
        self.cpu.set(share: share, caption: percent(share))
        self.memory.set(share: pressure, caption: percent(pressure))
        self.heat.set(share: value, caption: heatTitle)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 10
        let w = max(40, (bounds.width - gap * 2) / 3)
        cpu.frame = NSRect(x: 0, y: 0, width: w, height: bounds.height)
        memory.frame = NSRect(x: w + gap, y: 0, width: w, height: bounds.height)
        heat.frame = NSRect(x: (w + gap) * 2, y: 0, width: w, height: bounds.height)
    }

    private func percent(_ share: Double) -> String {
        String(format: "%.0f%%", share * 100)
    }
}

/// Круговой индикатор доли.
private final class PulseDialView: NSView {
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var share: Double = 0

    init(title: String) {
        titleLabel = UtkaChrome.label(title, size: 11, color: UtkaChrome.dim)
        valueLabel = UtkaChrome.label("—", size: 12, weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        titleLabel.alignment = .center
        valueLabel.alignment = .center
        track.fillColor = nil
        track.lineWidth = 5
        track.lineCap = .round
        fill.fillColor = nil
        fill.lineWidth = 5
        fill.lineCap = .round
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        addSubview(titleLabel)
        addSubview(valueLabel)
        applyLook()
    }

    required init?(coder: NSCoder) { nil }

    func applyLook() {
        titleLabel.textColor = UtkaChrome.dim
        titleLabel.font = UtkaChrome.font(11)
        valueLabel.textColor = UtkaChrome.ink
        valueLabel.font = UtkaChrome.font(12, weight: .medium)
        track.strokeColor = UtkaChrome.card.cgColor
        fill.strokeColor = IslandLook.accent.cgColor
        redraw()
    }

    func set(share: Double, caption: String) {
        self.share = min(1, max(0, share))
        valueLabel.stringValue = caption
        redraw()
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 14, width: bounds.width, height: 14)
        valueLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        redraw()
    }

    private func redraw() {
        let side = min(bounds.width, max(24, bounds.height - 30))
        let rect = NSRect(
            x: (bounds.width - side) / 2,
            y: 16 + (bounds.height - 30 - side) / 2,
            width: side,
            height: side
        ).insetBy(dx: 4, dy: 4)
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .pi * 1.15,
            endAngle: .pi * -0.15,
            clockwise: false
        )
        track.path = path
        let progress = CGMutablePath()
        let end = .pi * 1.15 + (.pi * 1.3) * CGFloat(share)
        progress.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .pi * 1.15,
            endAngle: end,
            clockwise: false
        )
        fill.path = progress
    }
}

/// Строка виновника: иконка, имя, процессор, память, «Закрыть».
private final class PulseAppRow: NSView {
    var onQuit: ((String) -> Void)?
    private let iconView = NSImageView()
    private let nameLabel = UtkaChrome.label("", size: 12, weight: .medium)
    private let cpuLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let memLabel = UtkaChrome.label("", size: 11, color: UtkaChrome.dim)
    private let quitButton = NSButton()
    private var key = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.imageScaling = .scaleProportionallyDown
        quitButton.title = "Закрыть"
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.font = UtkaChrome.font(11, weight: .medium)
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(cpuLabel)
        addSubview(memLabel)
        addSubview(quitButton)
        applyLook()
    }

    required init?(coder: NSCoder) { nil }

    func applyLook() {
        nameLabel.textColor = UtkaChrome.ink
        nameLabel.font = UtkaChrome.font(12, weight: .medium)
        cpuLabel.textColor = UtkaChrome.dim
        cpuLabel.font = UtkaChrome.font(11)
        memLabel.textColor = UtkaChrome.dim
        memLabel.font = UtkaChrome.font(11)
        quitButton.font = UtkaChrome.font(11, weight: .medium)
        quitButton.appearance = IslandLook.appearance
    }

    func show(_ app: PulseApp) {
        key = app.key
        iconView.image = app.icon
        nameLabel.stringValue = app.name
        cpuLabel.stringValue = PulseReader.formatCPU(app.cpuPercent)
        memLabel.stringValue = PulseReader.formatMemory(app.memoryBytes)
        quitButton.isHidden = !app.canQuit
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let icon: CGFloat = 18
        iconView.frame = NSRect(x: 0, y: (h - icon) / 2, width: icon, height: icon)
        let quitW: CGFloat = quitButton.isHidden ? 0 : 68
        if !quitButton.isHidden {
            quitButton.frame = NSRect(x: bounds.width - quitW, y: max(0, (h - 20) / 2), width: quitW, height: min(20, h))
        }
        let memW: CGFloat = 58
        let cpuW: CGFloat = 48
        let right = bounds.width - quitW - (quitButton.isHidden ? 0 : 6)
        memLabel.frame = NSRect(x: right - memW, y: 0, width: memW, height: h)
        cpuLabel.frame = NSRect(x: memLabel.frame.minX - cpuW - 4, y: 0, width: cpuW, height: h)
        let nameX = iconView.frame.maxX + 6
        nameLabel.frame = NSRect(
            x: nameX,
            y: 0,
            width: max(20, cpuLabel.frame.minX - nameX - 6),
            height: h
        )
    }

    @objc private func quitTapped() {
        onQuit?(key)
    }
}

/// Короткое окно-вопрос в хроме утки перед закрытием программы.
final class PulseQuitPrompt: NSObject {
    var onChoose: ((Bool) -> Void)?

    private let window: PulseAskWindow
    private let card = UtkaPanelChrome()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let yesButton = NSButton()
    private let noButton = NSButton()
    private var escapeMonitor: Any?
    private var lookToken: NSObjectProtocol?
    private var closed = false

    init(text: String) {
        window = PulseAskWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 128),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.cancel = { [weak self] in self?.finish(ok: false) }
        window.contentView = card

        message.stringValue = text
        message.font = UtkaChrome.font(13)
        message.maximumNumberOfLines = 3
        message.lineBreakMode = .byWordWrapping
        message.drawsBackground = false
        message.isBezeled = false
        message.isEditable = false
        message.isSelectable = false
        card.addSubview(message)

        style(yesButton, title: "Закрыть", action: #selector(yesTapped))
        style(noButton, title: "Оставить", action: #selector(noTapped))
        card.addSubview(yesButton)
        card.addSubview(noButton)
        lookToken = UtkaChrome.track(window) { [weak self] in
            self?.applyLook()
        }
    }

    private func applyLook() {
        card.apply()
        message.textColor = UtkaChrome.ink
        yesButton.appearance = window.appearance
        noButton.appearance = window.appearance
    }

    /// Карточка по центру островка.
    func show(over host: NSWindow?) {
        let cardW: CGFloat = 340
        let cardH: CGFloat = 128
        let area = host?.frame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: cardW, height: cardH)
        window.setFrame(
            NSRect(x: area.midX - cardW / 2, y: area.midY - cardH / 2, width: cardW, height: cardH),
            display: false
        )
        layoutCard()
        window.orderFrontRegardless()
        window.makeKey()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.finish(ok: false)
            return nil
        }
    }

    private func style(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.font = UtkaChrome.font(13, weight: .medium)
        button.target = self
        button.action = action
    }

    private func layoutCard() {
        let cardW: CGFloat = 340
        let pad: CGFloat = 16
        message.frame = NSRect(x: pad, y: 52, width: cardW - pad * 2, height: 56)
        let buttonW: CGFloat = 100
        let buttonH: CGFloat = 28
        noButton.frame = NSRect(x: cardW - pad - buttonW, y: 14, width: buttonW, height: buttonH)
        yesButton.frame = NSRect(x: noButton.frame.minX - 8 - buttonW, y: 14, width: buttonW, height: buttonH)
    }

    @objc private func yesTapped() { finish(ok: true) }
    @objc private func noTapped() { finish(ok: false) }

    private func finish(ok: Bool) {
        guard !closed else { return }
        closed = true
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let lookToken {
            NotificationCenter.default.removeObserver(lookToken)
            self.lookToken = nil
        }
        window.orderOut(nil)
        onChoose?(ok)
    }
}

/// Безрамочное окно вопроса. Escape ничего не закрывает.
private final class PulseAskWindow: NSWindow {
    var cancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        cancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel?()
            return
        }
        super.keyDown(with: event)
    }
}
