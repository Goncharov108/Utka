import AppKit
import CryptoKit

/// Свой офлайн-переводчик en↔ru: не Apple, не Google, не какой-либо
/// сторонний сервис. Движок и модели — из отдельного репозитория
/// Goncharov108/utka-translate, скачиваются один раз в поддержку утки и
/// дальше работают полностью локально, без единого обращения в сеть.
enum NativeTranslate {
    /// Понятный текст вместо сырого «Bad CPU type in executable».
    static let wrongProcessorMessage = "Движок не для этого процессора — скачайте заново в настройках"

    #if arch(arm64)
    private static let releaseURL = URL(
        string: "https://github.com/Goncharov108/utka-translate/releases/download/v0.1.0-runtime-macos-arm64/utka-translate-macos-arm64.zip"
    )!
    /// SHA-256 архива v0.1.0-runtime-macos-arm64.
    private static let expectedSHA256 = "622a640cd30632ae5b8b7f1bad1a9e78ceab11f65b007edbfc3c4be16e3263c1"
    /// CPU_TYPE_ARM64 в заголовке Mach-O.
    private static let hostCPUType: UInt32 = 0x0100000c
    #elseif arch(x86_64)
    private static let releaseURL = URL(
        string: "https://github.com/Goncharov108/utka-translate/releases/download/v0.1.1-runtime-macos-x86_64/utka-translate-macos-x86_64.zip"
    )!
    /// SHA-256 архива v0.1.1-runtime-macos-x86_64.
    private static let expectedSHA256 = "b96a903d32b348aab520103d23c4b0eee78b8595c26eef9296d514f9d7d8b290"
    /// CPU_TYPE_X86_64 в заголовке Mach-O.
    private static let hostCPUType: UInt32 = 0x01000007
    #else
    #error("Движок перевода собран только для arm64 и x86_64")
    #endif

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
    /// Чужая архитектура не считается установкой: кнопка «Скачать» остаётся.
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: modelsDir.path)
            && executableMatchesThisMac(binary)
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
            return .failure(failure(from: error))
        }
        process.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !output.isEmpty else {
            let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(failure(from: errText))
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
                // Старую папку сносим целиком: модели приедут в новом архиве,
                // и библиотеки другой архитектуры не останутся рядом.
                let engine = root.appendingPathComponent("utka-translate", isDirectory: true)
                if FileManager.default.fileExists(atPath: engine.path) {
                    try FileManager.default.removeItem(at: engine)
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

    /// Отпечаток файла по кускам: архив целиком в память не читаем.
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

    /// Заголовок Mach-O совпадает с процессором этой утки. Файл не запускаем.
    private static func executableMatchesThisMac(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512), data.count >= 8 else { return false }
        return machoMatchesHost(data)
    }

    /// Читает magic и cputype тонкого файла или список архитектур универсального.
    private static func machoMatchesHost(_ data: Data) -> Bool {
        guard let magic = u32(data, 0, bigEndian: false) else { return false }
        if magic == 0xFEEDFACF || magic == 0xFEEDFACE {
            return u32(data, 4, bigEndian: false) == hostCPUType
        }
        if magic == 0xCFFAEDFE || magic == 0xCEFAEDFE {
            guard let cpu = u32(data, 4, bigEndian: false) else { return false }
            return cpu.byteSwapped == hostCPUType
        }
        let fatBE = magic == 0xBEBAFECA
        let fatLE = magic == 0xCAFEBABE
        guard fatBE || fatLE, let count = u32(data, 4, bigEndian: fatBE), (1..<16).contains(count) else {
            return false
        }
        var offset = 8
        for _ in 0..<Int(count) {
            guard let cpu = u32(data, offset, bigEndian: fatBE) else { return false }
            if cpu == hostCPUType { return true }
            offset += 20
        }
        return false
    }

    /// Четыре байта заголовка. У тонкого Mach-O они в порядке этого Мака, у fat — часто наоборот.
    private static func u32(_ data: Data, _ offset: Int, bigEndian: Bool) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    /// «Bad CPU type» — и код POSIX 86, и текст из stderr — заменяем на одну фразу.
    private static func failure(from error: Error) -> TranslateFailure {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EBADARCH) {
            return TranslateFailure(message: wrongProcessorMessage)
        }
        return failure(from: ns.localizedDescription)
    }

    private static func failure(from raw: String) -> TranslateFailure {
        if raw.localizedCaseInsensitiveContains("Bad CPU type") {
            return TranslateFailure(message: wrongProcessorMessage)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranslateFailure(message: trimmed.isEmpty ? "Свой переводчик не ответил" : trimmed)
    }
}
