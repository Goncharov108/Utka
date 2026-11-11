import AppKit

/// Плагин «Утка звук» из отдельного будущего выпуска Goncharov108, не из репозитория утки.
enum SoundPlugin {
    /// Релиза ещё нет. Ссылку не подставляем, пока Goncharov108 его не опубликует.
    private static let releaseURL: URL? = nil
    private static let hal = "/Library/Audio/Plug-Ins/HAL"
    private static let driverName = "UtkaAudio.driver"

    /// Уже стоит в системной папке. Сборка его оттуда не стирает.
    static var isInstalled: Bool {
        let binary = (hal as NSString).appendingPathComponent("\(driverName)/Contents/MacOS/UtkaAudio")
        return FileManager.default.fileExists(atPath: binary)
    }

    /// Качает zip и ставит драйвер в системную папку. nil — получилось или ставить нечего.
    static func install(completion: @escaping (String?) -> Void) {
        guard let releaseURL else {
            DispatchQueue.main.async { completion("Файл ещё не опубликован") }
            return
        }
        download(releaseURL, completion: completion)
    }

    /// Повторяет скачивание перевода: чужой ответ сервера за архив не принимается.
    private static func download(_ url: URL, completion: @escaping (String?) -> Void) {
        let root = UtkaPaths.support.appendingPathComponent("SoundPlugin", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("download.zip")
        URLSession.shared.downloadTask(with: url) { location, response, error in
            if let error {
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                DispatchQueue.main.async {
                    completion("Сервер вернул ошибку \(http.statusCode) — файл ещё не опубликован или недоступен")
                }
                return
            }
            guard let location else {
                DispatchQueue.main.async { completion("Файл не пришёл") }
                return
            }
            do {
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: location, to: zip)
                let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
                try? FileManager.default.removeItem(at: unpacked)
                try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try unzip(zip, into: unpacked)
                try? FileManager.default.removeItem(at: zip)
                guard let bundle = findDriver(in: unpacked) else {
                    DispatchQueue.main.async { completion("Распаковалось, но файлы не на месте") }
                    return
                }
                let message = copyDriver(bundle)
                DispatchQueue.main.async { completion(message) }
            } catch {
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }.resume()
    }

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-oq", zip.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Utka", code: 1, userInfo: [NSLocalizedDescriptionKey: "unzip завершился с ошибкой"])
        }
    }

    /// Ищет распакованный бандл. Уже стоящий в системе драйвер не трогает.
    private static func findDriver(in dir: URL) -> URL? {
        guard let items = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in items where url.lastPathComponent == driverName {
            return url
        }
        return nil
    }

    /// Кладёт драйвер в HAL. Если он уже стоит — не удаляет и не перезаписывает.
    /// Пути никогда не склеиваются в строку для оболочки: имена папок внутри
    /// скачанного архива задаёт его автор, и кавычка в таком имени иначе
    /// превратилась бы в команду, выполненную с правами администратора.
    private static func copyDriver(_ bundle: URL) -> String? {
        let dest = (hal as NSString).appendingPathComponent(driverName)
        if FileManager.default.fileExists(atPath: dest) { return nil }
        if FileManager.default.isWritableFile(atPath: hal) {
            do {
                try FileManager.default.createDirectory(atPath: hal, withIntermediateDirectories: true)
                try FileManager.default.copyItem(atPath: bundle.path, toPath: dest)
                return nil
            } catch {
                return "Не удалось поставить плагин"
            }
        }
        return copyWithPassword(from: bundle.path, to: dest)
    }

    /// Запрос пароля системы. Пути уходят отдельными аргументами, а в AppleScript
    /// экранируются через `quoted form of`, не через ручную подстановку.
    private static func copyWithPassword(from source: String, to dest: String) -> String? {
        let script = [
            "on run argv",
            "set hal to quoted form of (item 1 of argv)",
            "set src to quoted form of (item 2 of argv)",
            "set dst to quoted form of (item 3 of argv)",
            "do shell script \"/bin/mkdir -p \" & hal & \" && /bin/cp -R \" & src & \" \" & dst with prompt \"Утке нужно поставить выход звука в системную папку.\" with administrator privileges",
            "end run"
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = script.flatMap { ["-e", $0] } + ["--", hal, source, dest]
        do {
            try process.run()
        } catch {
            return "Не удалось поставить плагин"
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "Не удалось поставить плагин"
    }
}
