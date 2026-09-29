import AppKit

/// Сверка сборки с общим main utka-apps и установка: забрать коммиты, собрать, открыть заново.
enum AppUpdate {
    struct Report {
        var text: String
        var canInstall: Bool
    }

    /// Что в общем main есть такого, чего нет в этой сборке.
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
        let tip = git(repo, ["log", "-1", "--format=%s", "\(remote)/main"]).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.isEmpty else {
            return Report(text: "В общем main пусто", canInstall: false)
        }
        let built = Bundle.main.object(forInfoDictionaryKey: "UtkaBuiltCommit") as? String ?? ""
        guard !built.isEmpty else {
            return Report(text: "В общем main:\n\(tip)", canInstall: true)
        }
        let log = git(repo, ["log", "--format=%s", "\(built)..\(remote)/main"])
        guard log.code == 0 else {
            return Report(text: "В общем main:\n\(tip)", canInstall: true)
        }
        let subjects = log.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !subjects.isEmpty else {
            return Report(text: "Новее общего main ничего нет", canInstall: false)
        }
        return Report(text: summary(subjects), canInstall: true)
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
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "nohup /bin/bash \(bashQuote(scriptURL.path)) </dev/null >/dev/null 2>&1 &"]
        process.currentDirectoryURL = repo
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }

    /// Подтягивает main в refs/remotes/…/main, а не только во временный FETCH_HEAD.
    private static func fetchMain(_ repo: URL, _ remote: String) -> Bool {
        git(repo, ["fetch", remote, "+refs/heads/main:refs/remotes/\(remote)/main"], capture: false, timeout: 45).code == 0
    }

    /// Первые правки списком, остальные — числом.
    private static func summary(_ subjects: [String]) -> String {
        let shown = subjects.prefix(4)
        var lines = ["Готово:"]
        lines.append(contentsOf: shown.map { "— \($0)" })
        let rest = subjects.count - shown.count
        if rest > 0 {
            lines.append("и ещё \(rest)")
        }
        return lines.joined(separator: "\n")
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
        driver=\(bashQuote(driver))
        before=""
        if [ -f "$driver" ]; then
          before=$(shasum -a 256 "$driver" | awk '{print $1}')
        fi
        if ! bash scripts/build-app.sh; then
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
