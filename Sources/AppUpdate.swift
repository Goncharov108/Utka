import AppKit

/// Сверка номера с общим main utka-apps, установка и возврат предыдущей утки.
enum AppUpdate {
    struct Report {
        var text: String
        var canInstall: Bool
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
        if current == remoteNote.version {
            return Report(
                text: "Сейчас \(currentLabel)\nВ общем main \(withVee(remoteNote.version))\nСтавить нечего",
                canInstall: false
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
        let dirty = git(repo, ["status", "--porcelain", "--untracked-files=no"])
        guard dirty.code == 0 else { return "Не удалось проверить папку" }
        if !dirty.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "В папке есть несохранённые правки"
        }
        guard fetchMain(repo, remote) else {
            return "Не удалось забрать общий main"
        }
        if git(repo, ["merge", "--ff-only", "\(remote)/main"]).code == 0 {
            return nil
        }
        if git(repo, ["merge", "--no-edit", "\(remote)/main"]).code == 0 {
            return nil
        }
        _ = git(repo, ["merge", "--abort"])
        return "Общий main не лёг поверх текущей ветки"
    }

    /// Собирает приложение после выхода текущего процесса и открывает его снова.
    static func startRebuild() -> Bool {
        guard let repo = repoRoot() else { return false }
        let log = UtkaPaths.support.appendingPathComponent("update.log")
        let scriptURL = UtkaPaths.support.appendingPathComponent("update.sh")
        let script = rebuildScript(
            repo: repo,
            log: log,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        guard writeExecutable(script, to: scriptURL) else { return false }
        return launchDetached(scriptURL, in: repo)
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

    /// Скрипт переживает выход утки: дожидается процесса, собирает и открывает.
    private static func rebuildScript(repo: URL, log: URL, pid: Int32) -> String {
        let driver = "/Library/Audio/Plug-Ins/HAL/UtkaAudio.driver/Contents/MacOS/UtkaAudio"
        return """
        #!/bin/bash
        set -u
        export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        exec >\(bashQuote(log.path)) 2>&1
        cd \(bashQuote(repo.path)) || exit 1
        \(waitSnippet(pid: pid))
        driver=\(bashQuote(driver))
        before=""
        if [ -f "$driver" ]; then
          before=$(shasum -a 256 "$driver" | awk '{print $1}')
        fi
        if ! UTKA_INSTALL=1 bash scripts/build-app.sh; then
          osascript -e 'display alert "Утка не собралась" message "Подробности в ~/Library/Application Support/Utka/update.log"' || true
          exit 1
        fi
        after=""
        if [ -f "$driver" ]; then
          after=$(shasum -a 256 "$driver" | awk '{print $1}')
        fi
        if [ "$before" != "$after" ]; then
          osascript -e 'do shell script "killall coreaudiod" with prompt "Утке нужно перезапустить системный звук, чтобы подхватить новый выход." with administrator privileges' || true
        fi
        open \(bashQuote(repo.appendingPathComponent("Utka.app").path))
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
