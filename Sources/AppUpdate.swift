import AppKit

/// Сверка номера с общим main utka-apps, установка и возврат предыдущей утки.
enum AppUpdate {
    struct Report {
        var text: String
        var canInstall: Bool
        /// true — свежая сверка подтвердила, что новее на main ничего нет.
        /// Не просто «canInstall == false»: так тоже помечаются сбои сверки
        /// (нет сети, нет папки и т.д.), их зелёным красить не нужно.
        var isUpToDate: Bool = false
    }

    /// Номер с общего main и текст, что лежит в этом обновлении.
    static func look() -> Report {
        guard let repo = repoRoot() else {
            return Report(text: "Рядом с приложением нет папки с кодом", canInstall: false)
        }
        guard let remote = sharedRemote(in: repo) else {
            return Report(text: "Нет общего репозитория utka-apps", canInstall: false)
        }
        guard fetchMain(repo, remote) else {
            return Report(text: "Не удалось свериться с общим main", canInstall: false)
        }
        let shown = git(repo, ["show", "\(remote)/main:VERSION"])
        guard shown.code == 0, let remoteNote = parseVersionFile(shown.out) else {
            return Report(text: "Обновлений нет", canInstall: false)
        }
        let current = installedVersion()
        let currentLabel = current.map(withVee) ?? "номер сборки неизвестен"
        // Сравниваем как числа, а не строки: иначе после ручной пересборки
        // локальный номер может обогнать main, и «Новая v1.0.3» при уже
        // установленной v1.0.4 выглядело бы так, будто есть обновление.
        guard let current else {
            return Report(text: "Номер сборки неизвестен, сверить не с чем", canInstall: false)
        }
        guard isNewer(remoteNote.version, than: current) else {
            return Report(
                text: "Сейчас \(currentLabel)\nОбновлений нет — у вас последняя версия",
                canInstall: false,
                isUpToDate: true
            )
        }
        var lines = ["Сейчас \(currentLabel)", "Новая \(withVee(remoteNote.version))"]
        if remoteNote.note.isEmpty {
            lines.append("Описания этого обновления на общем main нет")
        } else {
            lines.append(remoteNote.note)
        }
        return Report(text: lines.joined(separator: "\n"), canInstall: true)
    }

    /// Кладёт общий main в текущую ветку. nil — можно собирать. Текст — почему нельзя.
    static func prepareInstall() -> String? {
        guard let repo = repoRoot() else { return "Рядом с приложением нет папки с кодом" }
        guard let remote = sharedRemote(in: repo) else { return "Нет общего репозитория utka-apps" }
        if let error = discardStrayVersionFile(repo) {
            return error
        }
        guard fetchMain(repo, remote) else {
            return "Не удалось забрать общий main"
        }
        dropAutomaticVersionCommits(repo, remote: remote)
        if git(repo, ["merge", "--ff-only", "\(remote)/main"]).code == 0 {
            return nil
        }
        if git(repo, ["merge", "--no-edit", "\(remote)/main"]).code == 0 {
            return nil
        }
        _ = git(repo, ["merge", "--abort"])
        return "Общий main не лёг поверх текущей ветки"
    }

    /// Если в папке изменён только номер, возвращает файл как в последнем сохранении.
    /// Другие правки по-прежнему останавливают установку.
    private static func discardStrayVersionFile(_ repo: URL) -> String? {
        let dirty = git(repo, ["status", "--porcelain", "--untracked-files=no"])
        guard dirty.code == 0 else { return "Не удалось проверить папку" }
        let lines = dirty.out.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if lines.isEmpty { return nil }
        let onlyVersion = lines.allSatisfy { line in
            !line.contains(" -> ") && line.split(separator: " ").last == "VERSION"
        }
        guard onlyVersion else { return "В папке есть несохранённые правки" }
        guard git(repo, ["checkout", "HEAD", "--", "VERSION"]).code == 0 else {
            return "В папке есть несохранённые правки"
        }
        return nil
    }

    /// Снимает с кончика ветки сохранения «Версия 1.0.5», которых нет на общем main.
    /// Такие пишет старая локальная сборка. Чужие правки не трогает.
    private static func dropAutomaticVersionCommits(_ repo: URL, remote: String) {
        let listed = git(repo, ["rev-list", "--first-parent", "\(remote)/main..HEAD"])
        guard listed.code == 0 else { return }
        var count = 0
        for raw in listed.out.split(whereSeparator: \.isNewline) {
            let commit = String(raw).trimmingCharacters(in: .whitespaces)
            guard !commit.isEmpty, isAutomaticVersionCommit(repo, commit) else { break }
            count += 1
        }
        guard count > 0 else { return }
        _ = git(repo, ["reset", "--hard", "HEAD~\(count)"])
    }

    /// Сохранение старой сборки: подпись «Версия 1.2.3» и в нём только файл номера.
    private static func isAutomaticVersionCommit(_ repo: URL, _ commit: String) -> Bool {
        let subject = git(repo, ["log", "-1", "--format=%s", commit])
        guard subject.code == 0 else { return false }
        let title = subject.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.range(of: #"^Версия [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            return false
        }
        let files = git(repo, ["diff-tree", "--no-commit-id", "--name-only", "-r", commit])
        guard files.code == 0 else { return false }
        let names = files.out.split(whereSeparator: \.isNewline).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return names == ["VERSION"]
    }

    /// Уже стоящий звуковой плагин. Хеш снимается до сборки, вопрос пароля — после.
    private static let driverBinary = "/Library/Audio/Plug-Ins/HAL/UtkaAudio.driver/Contents/MacOS/UtkaAudio"

    /// Временный бандл кнопки «Установить». Запущенный Utka.app это не он.
    private static func stageBundle() -> URL {
        UtkaPaths.support.appendingPathComponent("Utka.next.app", isDirectory: true)
    }

    /// Хеш уже стоящего плагина. Пусто, если файла нет.
    static func driverFingerprint() -> String {
        let path = driverBinary
        guard FileManager.default.fileExists(atPath: path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Собирает утку во временный бандл, пока этот процесс жив. nil — вышло.
    /// onStep приходит не с главного потока: previous, arm64, skip arm64 и другие строки шага.
    static func runStagedBuild(onStep: @escaping (String) -> Void) -> String? {
        guard let repo = repoRoot() else { return "Сборка не вышла" }
        let log = UtkaPaths.support.appendingPathComponent("update.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: log) else {
            return "Сборка не вышла"
        }
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/build-app.sh"]
        process.currentDirectoryURL = repo
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["UTKA_INSTALL"] = "1"
        env["UTKA_STAGE"] = stageBundle().path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = handle
        let buffer = InstallStepBuffer()
        let readLock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { pipeHandle in
            readLock.lock()
            let data = pipeHandle.availableData
            buffer.append(data, emit: onStep)
            readLock.unlock()
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            removeStage()
            return "Сборка не вышла"
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        readLock.lock()
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        buffer.append(rest, emit: onStep)
        buffer.finish(emit: onStep)
        readLock.unlock()
        if process.terminationStatus != 0 {
            removeStage()
            return "Сборка не вышла"
        }
        return nil
    }

    /// После успешной сборки ставит новый бандл на место и открывает его. Git не трогает.
    static func startHandoff(driverBefore: String) -> Bool {
        guard let repo = repoRoot() else { return false }
        let scriptURL = UtkaPaths.support.appendingPathComponent("update.sh")
        let script = handoffScript(
            live: Bundle.main.bundleURL,
            stage: stageBundle(),
            driverBefore: driverBefore,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        guard writeExecutable(script, to: scriptURL) else { return false }
        return launchDetached(scriptURL, in: repo)
    }

    /// Снимает временный бандл, если сборка не вышла. Запущенную утку не трогает.
    private static func removeStage() {
        let url = stageBundle()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Ставит предыдущую утку на место текущей. nil — скрипт запущен. Текст — почему нельзя.
    static func startRestore() -> String? {
        let previous = previousBundle()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: previous.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Возвращать нечего"
        }
        let current = Bundle.main.bundleURL
        let scriptURL = UtkaPaths.support.appendingPathComponent("restore.sh")
        let script = restoreScript(current: current, previous: previous, pid: ProcessInfo.processInfo.processIdentifier)
        guard writeExecutable(script, to: scriptURL) else {
            return "Не удалось начать возврат"
        }
        return launchDetached(scriptURL, in: current.deletingLastPathComponent()) ? nil : "Не удалось начать возврат"
    }

    /// Подтягивает main в refs/remotes/…/main, а не только во временный FETCH_HEAD.
    private static func fetchMain(_ repo: URL, _ remote: String) -> Bool {
        git(repo, ["fetch", remote, "+refs/heads/main:refs/remotes/\(remote)/main"], capture: false, timeout: 45).code == 0
    }

    /// Первая строка файла версии — три числа, дальше описание человеческим языком.
    private static func parseVersionFile(_ text: String) -> (version: String, note: String)? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              isThreePart(first) else { return nil }
        let note = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (first, note)
    }

    /// Номер уже собранного приложения, не из рабочей копии файла версии.
    private static func installedVersion() -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isThreePart(text) ? text : nil
    }

    /// Три числа через точку, без буквы v.
    private static func isThreePart(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Номер в настройках: v1.0.0.
    private static func withVee(_ version: String) -> String {
        "v\(version)"
    }

    /// Три числа как кортеж, чтобы v1.0.10 не проиграл v1.0.9 из-за строкового сравнения.
    private static func triple(_ version: String) -> (Int, Int, Int)? {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    /// true — на main действительно более новый номер, а не такой же или старее.
    private static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let remoteTriple = triple(remote), let currentTriple = triple(current) else {
            return remote != current
        }
        return remoteTriple > currentTriple
    }

    /// Копия утки, которую сборка оставляет перед заменой.
    private static func previousBundle() -> URL {
        UtkaPaths.support.appendingPathComponent("PreviousUtka.app", isDirectory: true)
    }

    /// Папка репозитория, если приложение лежит в ней.
    private static func repoRoot() -> URL? {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let top = git(parent, ["rev-parse", "--show-toplevel"])
        guard top.code == 0 else { return nil }
        let path = top.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Удалённый utka-apps/utka, не личная копия.
    private static func sharedRemote(in repo: URL) -> String? {
        let listed = git(repo, ["remote", "-v"])
        guard listed.code == 0 else { return nil }
        var names: [String] = []
        for line in listed.out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].contains("utka-apps/utka") else { continue }
            if !names.contains(parts[0]) {
                names.append(parts[0])
            }
        }
        if names.contains("utka-apps") { return "utka-apps" }
        return names.first
    }

    /// Ждёт выход утки, ставит собранный бандл на место и открывает его. Сборку не запускает.
    private static func handoffScript(live: URL, stage: URL, driverBefore: String, pid: Int32) -> String {
        let hold = UtkaPaths.support.appendingPathComponent("Utka.swap.app")
        return """
        #!/bin/bash
        set -u
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        \(waitSnippet(pid: pid))
        live=\(bashQuote(live.path))
        stage=\(bashQuote(stage.path))
        hold=\(bashQuote(hold.path))
        say_fail() {
          osascript -e 'display alert "Не удалось поставить новую утку"' || true
          if [ -x "$live/Contents/MacOS/Utka" ]; then
            open "$live" || true
          fi
          exit 1
        }
        rm -rf "$hold"
        mv "$live" "$hold" || say_fail
        mv "$stage" "$live" || { mv "$hold" "$live" || true; say_fail; }
        rm -rf "$hold"
        driver=\(bashQuote(driverBinary))
        before=\(bashQuote(driverBefore))
        after=""
        if [ -f "$driver" ]; then
          after=$(shasum -a 256 "$driver" | awk '{print $1}')
        fi
        if [ "$before" != "$after" ]; then
          osascript -e 'do shell script "killall coreaudiod" with prompt "Утке нужно перезапустить системный звук, чтобы подхватить новый выход." with administrator privileges' || true
        fi
        open "$live"
        """
    }

    /// Меняет текущую утку и копию местами. Git не вызывает.
    private static func restoreScript(current: URL, previous: URL, pid: Int32) -> String {
        let hold = previous.deletingLastPathComponent().appendingPathComponent("Utka.hold.app")
        return """
        #!/bin/bash
        set -u
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        \(waitSnippet(pid: pid))
        current=\(bashQuote(current.path))
        previous=\(bashQuote(previous.path))
        hold=\(bashQuote(hold.path))
        say_fail() {
          osascript -e 'display alert "Не удалось вернуть предыдущую утку"' || true
          exit 1
        }
        rm -rf "$hold"
        mv "$current" "$hold" || say_fail
        mv "$previous" "$current" || { mv "$hold" "$current" || true; say_fail; }
        mv "$hold" "$previous" || say_fail
        open "$current"
        """
    }

    /// Дожидается выхода утки, чтобы заменить её папку.
    private static func waitSnippet(pid: Int32) -> String {
        """
        pid=\(pid)
        if [ "$pid" -gt 0 ]; then
          kill -TERM "$pid" 2>/dev/null || true
          for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
          done
          kill -KILL "$pid" 2>/dev/null || true
          sleep 0.2
        fi
        """
    }

    /// Пишет скрипт, который переживёт выход утки.
    private static func writeExecutable(_ script: String, to url: URL) -> Bool {
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    /// Запускает скрипт в фоне и не ждёт, пока утка закроется.
    private static func launchDetached(_ scriptURL: URL, in directory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash \(bashQuote(scriptURL.path)) </dev/null >/dev/null 2>&1 &"]
        process.currentDirectoryURL = directory
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    /// Кавычки для пути в bash.
    private static func bashQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// git в папке репозитория. Без запроса пароля в терминале.
    private static func git(_ repo: URL, _ args: [String], capture: Bool = true, timeout: TimeInterval = 30) -> (code: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        process.environment = env
        let pipe = Pipe()
        if capture {
            process.standardOutput = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        let gate = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in gate.signal() }
        if gate.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            gate.wait()
            return (1, "")
        }
        let output = capture
            ? (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            : ""
        return (process.terminationStatus, output)
    }
}

/// Копит stdout сборки и отдаёт только строки шага.
private final class InstallStepBuffer {
    private var pending = Data()
    private let lock = NSLock()

    /// Забирает целые строки. Хвост без перевода строки остаётся до finish.
    func append(_ data: Data, emit: (String) -> Void) {
        let lines = lockedLines(adding: data, flush: false)
        lines.forEach { emitStep($0, emit: emit) }
    }

    /// Отдаёт недописанный хвост, если процесс уже кончился.
    func finish(emit: (String) -> Void) {
        let lines = lockedLines(adding: Data(), flush: true)
        lines.forEach { emitStep($0, emit: emit) }
    }

    /// Склеивает куски в строки. Пустой кусок ничего не стирает.
    private func lockedLines(adding data: Data, flush: Bool) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if !data.isEmpty {
            pending.append(data)
        }
        var lines: [String] = []
        let newline: UInt8 = 10
        while let index = pending.firstIndex(of: newline) {
            let chunk = pending.prefix(upTo: index)
            pending.removeSubrange(pending.startIndex...index)
            lines.append(decode(chunk))
        }
        if flush, !pending.isEmpty {
            lines.append(decode(pending))
            pending.removeAll()
        }
        return lines
    }

    /// Строка шага без префикса. Чужой stdout сборки пропускается.
    private func emitStep(_ line: String, emit: (String) -> Void) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("UTKA_STEP ") else { return }
        let token = String(trimmed.dropFirst("UTKA_STEP ".count)).trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        emit(token)
    }

    /// Байты строки без завершающего возврата каретки.
    private func decode(_ data: Data) -> String {
        var text = String(data: data, encoding: .utf8) ?? ""
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        return text
    }
}
