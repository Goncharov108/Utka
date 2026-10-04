import AppKit
import CryptoKit

/// Свой офлайн-переводчик en↔ru: не Apple, не Google, не какой-либо
/// сторонний сервис. Движок и модели — из отдельного репозитория
/// utka-apps/utka-translate, скачиваются один раз в поддержку утки и
/// дальше работают полностью локально, без единого обращения в сеть.
enum NativeTranslate {
    private static let releaseURL = URL(
        string: "https://github.com/utka-apps/utka-translate/releases/download/v0.1.0-runtime-macos-arm64/utka-translate-macos-arm64.zip"
    )!

    private static var root: URL {
        UtkaPaths.support.appendingPathComponent("Translate", isDirectory: true)
    }

    private static var binary: URL {
        root.appendingPathComponent("utka-translate/utka-translate")
    }

    private static var modelsDir: URL {
        root.appendingPathComponent("utka-translate/models")
    }

    /// Стоит ли уже движок на диске и можно ли им пользоваться сейчас.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: modelsDir.path)
    }

    /// Переводит, если движок уже скачан. nil — не установлен, нужно вызвать download.
    static func translate(_ text: String, toEnglish: Bool) -> Result<String, TranslateFailure>? {
        guard isInstalled else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success("") }
        let from = toEnglish ? "ru" : "en"
        let to = toEnglish ? "en" : "ru"

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--dir", modelsDir.path, "--from", from, "--to", to, trimmed]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failure(TranslateFailure(message: error.localizedDescription))
        }
        process.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !output.isEmpty else {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(TranslateFailure(message: errText.isEmpty ? "Свой переводчик не ответил" : errText))
        }
        return .success(output)
    }

    /// Качает и распаковывает движок с моделями. completion(nil) — успех.
    static func download(completion: @escaping (String?) -> Void) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let zipPath = root.appendingPathComponent("download.zip")
        let task = URLSession.shared.downloadTask(with: releaseURL) { location, response, error in
            if let error {
                DispatchQueue.main.async { completion(error.localizedDescription) }
                return
            }
            // URLSession не считает 404/403 ошибкой сам по себе — без этой
            // проверки страница с текстом ошибки была бы принята за архив.
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
                try? FileManager.default.removeItem(at: zipPath)
                try FileManager.default.moveItem(at: location, to: zipPath)
                // Внутри архива исполняемый файл, поэтому сначала сверяем отпечаток
                // с тем, что мы сами опубликовали. Подмена файла на сервере или по
                // дороге не пройдёт: чужое не распаковывается и не запускается.
                guard let actual = sha256(of: zipPath), actual == expectedSHA256 else {
                    try? FileManager.default.removeItem(at: zipPath)
                    DispatchQueue.main.async {
                        completion("Скачанный файл не совпал с ожидаемым — установка отменена. Если вы только что обновляли движок, обновите и Утку")
                    }
                    return
                }
                try unzip(zipPath, into: root)
                try? FileManager.default.removeItem(at: zipPath)
                let ready = isInstalled
                DispatchQueue.main.async { completion(ready ? nil : "Распаковалось, но файлы не на месте") }
            } catch {
                DispatchQueue.main.async { completion(error.localizedDescription) }
            }
        }
        task.resume()
    }

    /// SHA-256 архива из релиза v0.1.0-runtime-macos-arm64. Меняется вместе со ссылкой выше:
    /// выпустили новый релиз — пересчитайте `shasum -a 256` и обновите оба значения.
    private static let expectedSHA256 = "622a640cd30632ae5b8b7f1bad1a9e78ceab11f65b007edbfc3c4be16e3263c1"

    /// Отпечаток файла по кускам: архив 144 МБ целиком в память не читаем.
    private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func unzip(_ zip: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-oq", zip.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranslateFailure(message: "unzip завершился с ошибкой")
        }
        // На случай, если macOS пометила скачанный файл карантином, и на
        // случай, если zip не сохранил бит запуска.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let unquarantine = Process()
        unquarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        unquarantine.arguments = ["-dr", "com.apple.quarantine", root.appendingPathComponent("utka-translate").path]
        try? unquarantine.run()
        unquarantine.waitUntilExit()
    }
}
