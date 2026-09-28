import AVFoundation
import CoreAudio
import Foundation

/// Куда сейчас играет Mac: выходы, громкость и беззвучие.
final class AudioOutput {
    static let shared = AudioOutput()

    /// Один выход, который можно выбрать одним касанием.
    struct Sink: Equatable {
        let id: AudioDeviceID
        let name: String
        let symbol: String
    }

    private(set) var sinks: [Sink] = []
    private(set) var currentID: AudioDeviceID = 0
    private(set) var volume: Float = 0
    private(set) var muted = false
    private(set) var canAdjustVolume = false
    private(set) var canMute = false
    var onChange: (() -> Void)?

    private let outputScope = kAudioObjectPropertyScopeOutput
    /// Селектор kAudioHardwareServiceDeviceProperty_VirtualMainVolume ('vmvc').
    private let virtualMainVolume = AudioObjectPropertySelector(0x766D7663)
    private let refreshLock = NSLock()
    private var refreshScheduled = false
    private var started = false
    private var levelDevice: AudioDeviceID = 0
    private var levelSelectors: [AudioObjectPropertySelector] = []
    private let virtualUID = "dev.goncharov.utka.output"
    private var virtualID: AudioDeviceID = 0
    private var playID: AudioDeviceID = 0
    private var routed = false
    private var didShutdown = false

    private init() {}

    /// Подписывается на появление устройств и смену выхода.
    func start() {
        guard !started else { return }
        started = true
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, add: true)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, add: true)
        refreshFromHardware()
        requestListenAccess()
    }

    /// macOS считает петлю «Утка звук» микрофоном. Пока доступ не дан, системный выход не переключаем.
    private func requestListenAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRoute()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.beginRoute() }
                }
            }
        default:
            break
        }
    }

    /// Если плагин загружен, системный выход становится «Утка звук», а железо только принимает поток.
    private func beginRoute() {
        guard !routed, UtkaPlayOpen() != 0 else { return }
        let found = deviceID(forUID: virtualUID)
        guard found != 0 else {
            UtkaPlayClose()
            return
        }
        virtualID = found
        let current = readDefaultOutput()
        if current != virtualID { playID = current }
        if playID == 0 || playID == virtualID {
            playID = outputSinks().first?.id ?? 0
        }
        guard playID != 0, UtkaPlayStart(UInt32(playID)) == 0 else {
            UtkaPlayClose()
            return
        }
        routed = true
        if current != virtualID, !setSystemOutput(virtualID) {
            routed = false
            UtkaPlayClose()
            return
        }
        refreshFromHardware()
    }

    /// Системный выход и системные звуки на одно устройство.
    private func setSystemOutput(_ id: AudioDeviceID) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let outputOK = writeValue(system, kAudioHardwarePropertyDefaultOutputDevice, id)
        let systemOK = writeValue(system, kAudioHardwarePropertyDefaultSystemOutputDevice, id)
        return outputOK && systemOK
    }

    /// Если меню macOS увело звук прямо в монитор, возвращает его в «Утка звук» на этот же монитор.
    private func ensureThroughVirtual() {
        guard routed, virtualID != 0 else { return }
        let current = readDefaultOutput()
        if current == 0 || current == virtualID { return }
        guard UtkaPlayStart(UInt32(current)) == 0 else { return }
        playID = current
        _ = setSystemOutput(virtualID)
    }

    /// Возвращает прежний выход, чтобы после выхода звук не остался в пустом кольце.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true
        let restore = playID
        let wasRouted = routed
        routed = false
        UtkaPlayClose()
        guard wasRouted, restore != 0, restore != virtualID else { return }
        _ = setSystemOutput(restore)
    }

    /// Выход, выбранный кнопкой на полосе.
    func select(buttonTag: Int) {
        guard buttonTag >= 0 else { return }
        select(AudioDeviceID(buttonTag))
    }

    /// Кнопка выбирает железо, а системный выход остаётся «Утка звук», чтобы ползунок был на пути.
    func select(_ id: AudioDeviceID) {
        if routed, virtualID != 0, id != virtualID {
            guard UtkaPlayStart(UInt32(id)) == 0 else { return }
            playID = id
            _ = setSystemOutput(virtualID)
            refreshFromHardware()
            return
        }
        guard setSystemOutput(id) else { return }
        refreshFromHardware()
    }

    /// Куда писать громкость: в виртуальный выход, пока маршрут включён.
    private func levelTarget() -> AudioDeviceID {
        if routed, virtualID != 0 { return virtualID }
        return currentID
    }

    /// Ставит громкость текущего выхода. Ненулевая снимает беззвучие.
    func setVolume(_ value: Float) {
        ensureThroughVirtual()
        let target = levelTarget()
        guard canAdjustVolume, target != 0 else { return }
        let clamped = min(1, max(0, value))
        writeVolume(target, clamped)
        volume = clamped
        if clamped > 0, muted, canMute {
            _ = writeValue(target, kAudioDevicePropertyMute, scope: outputScope, UInt32(0))
            muted = false
        }
        onChange?()
    }

    /// Переключает беззвучие текущего выхода.
    func toggleMute() {
        ensureThroughVirtual()
        let target = levelTarget()
        guard canMute, target != 0 else { return }
        muted.toggle()
        _ = writeValue(target, kAudioDevicePropertyMute, scope: outputScope, muted ? UInt32(1) : UInt32(0))
        onChange?()
    }

    /// Считывает список и текущую громкость с железа.
    func refreshFromHardware() {
        virtualID = deviceID(forUID: virtualUID)
        if !routed, virtualID != 0 { beginRoute() }
        sinks = outputSinks()
        if routed {
            if playID == 0 || !sinks.contains(where: { $0.id == playID }) {
                playID = sinks.first?.id ?? 0
                if playID != 0 { _ = UtkaPlayStart(UInt32(playID)) }
            }
            let live = readDefaultOutput()
            if live != 0, live != virtualID, sinks.contains(where: { $0.id == live }) {
                currentID = live
            } else {
                currentID = playID
            }
            if virtualID != levelDevice { bindLevels(to: virtualID) }
            canAdjustVolume = hasVolume(virtualID)
            canMute = hasProperty(virtualID, kAudioDevicePropertyMute, scope: outputScope)
            volume = canAdjustVolume ? readVolume(virtualID) : volume
            muted = canMute && readMuted(virtualID)
        } else {
            let current = readDefaultOutput()
            if current != currentID || current != levelDevice { bindLevels(to: current) }
            currentID = current
            canAdjustVolume = hasVolume(current)
            canMute = hasProperty(current, kAudioDevicePropertyMute, scope: outputScope)
            volume = canAdjustVolume ? readVolume(current) : 0
            muted = canMute && readMuted(current)
        }
        onChange?()
    }

    /// Ставит одно обновление интерфейса, даже если железо прислало пачку событий.
    fileprivate func enqueueRefresh() {
        refreshLock.lock()
        let already = refreshScheduled
        refreshScheduled = true
        refreshLock.unlock()
        guard !already else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshLock.lock()
            self.refreshScheduled = false
            self.refreshLock.unlock()
            self.refreshFromHardware()
        }
    }

    /// Слушает громкость того выхода, который играет сейчас.
    private func bindLevels(to id: AudioDeviceID) {
        if levelDevice != 0 {
            for selector in levelSelectors {
                listen(levelDevice, selector, scope: outputScope, add: false)
            }
            levelSelectors = []
            levelDevice = 0
        }
        guard id != 0 else { return }
        var selectors: [AudioObjectPropertySelector] = []
        if hasProperty(id, virtualMainVolume, scope: outputScope) {
            selectors.append(virtualMainVolume)
        } else if hasProperty(id, kAudioDevicePropertyVolumeScalar, scope: outputScope) {
            selectors.append(kAudioDevicePropertyVolumeScalar)
        }
        if hasProperty(id, kAudioDevicePropertyMute, scope: outputScope) {
            selectors.append(kAudioDevicePropertyMute)
        }
        for selector in selectors {
            listen(id, selector, scope: outputScope, add: true)
        }
        levelSelectors = selectors
        levelDevice = id
    }

    /// Выходы с каналами воспроизведения, кроме AirPlay.
    private func outputSinks() -> [Sink] {
        deviceIDs().compactMap { sink(for: $0) }
    }

    /// Имя, символ и право стать выходом по умолчанию.
    private func sink(for id: AudioDeviceID) -> Sink? {
        if readUID(id) == virtualUID { return nil }
        guard outputChannels(id) > 0, canBeDefaultOutput(id) else { return nil }
        let transport: UInt32 = readValue(id, kAudioDevicePropertyTransportType) ?? 0
        if transport == kAudioDeviceTransportTypeAirPlay { return nil }
        return Sink(id: id, name: readName(id), symbol: symbol(for: transport))
    }

    /// Число каналов воспроизведения. Ноль — это микрофон, его на полосе нет.
    private func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: outputScope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Устройство можно выбрать в меню звука.
    private func canBeDefaultOutput(_ id: AudioDeviceID) -> Bool {
        let flag: UInt32? = readValue(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: outputScope)
        return flag != 0
    }

    /// Есть ползунок: виртуальная громкость или скаляр на главном элементе.
    private func hasVolume(_ id: AudioDeviceID) -> Bool {
        hasProperty(id, virtualMainVolume, scope: outputScope) || hasProperty(id, kAudioDevicePropertyVolumeScalar, scope: outputScope)
    }

    /// Громкость 0…1. Сначала общая, как в меню macOS.
    private func readVolume(_ id: AudioDeviceID) -> Float {
        if let value: Float32 = readValue(id, virtualMainVolume, scope: outputScope) { return value }
        if let value: Float32 = readValue(id, kAudioDevicePropertyVolumeScalar, scope: outputScope) { return value }
        return 0
    }

    /// Пишет громкость туда, где устройство её принимает.
    private func writeVolume(_ id: AudioDeviceID, _ value: Float) {
        let sample = Float32(value)
        if hasProperty(id, virtualMainVolume, scope: outputScope) {
            _ = writeValue(id, virtualMainVolume, scope: outputScope, sample)
            return
        }
        _ = writeValue(id, kAudioDevicePropertyVolumeScalar, scope: outputScope, sample)
    }

    /// Беззвучие включено.
    private func readMuted(_ id: AudioDeviceID) -> Bool {
        let flag: UInt32? = readValue(id, kAudioDevicePropertyMute, scope: outputScope)
        return flag == 1
    }

    /// Текущий выход по умолчанию.
    private func readDefaultOutput() -> AudioDeviceID {
        readValue(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    }

    /// Все устройства, которые видит CoreAudio.
    private func deviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Устройство плагина по постоянному идентификатору.
    private func deviceID(forUID uid: String) -> AudioDeviceID {
        deviceIDs().first { readUID($0) == uid } ?? 0
    }

    /// Постоянный идентификатор устройства.
    private func readUID(_ id: AudioObjectID) -> String {
        readString(id, kAudioDevicePropertyDeviceUID)
    }

    /// Человеческое имя устройства.
    private func readName(_ id: AudioObjectID) -> String {
        let title = readString(id, kAudioObjectPropertyName)
        return title.isEmpty ? "Выход" : title
    }

    /// Строка свойства CoreAudio.
    private func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = propertyAddress(selector)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }

    /// Ноутбук, монитор или наушники — по тому, как устройство подключено.
    private func symbol(for transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt:
            return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        default:
            return "speaker.wave.2"
        }
    }

    /// Свойство есть у объекта.
    private func hasProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
        guard id != 0 else { return false }
        var address = propertyAddress(selector, scope: scope, element: element)
        return AudioObjectHasProperty(id, &address)
    }

    /// Вешает или снимает слушатель свойства.
    private func listen(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, add: Bool) {
        guard id != 0 else { return }
        var address = propertyAddress(selector, scope: scope)
        if add {
            AudioObjectAddPropertyListener(id, &address, audioHardwareChanged, nil)
        } else {
            AudioObjectRemovePropertyListener(id, &address, audioHardwareChanged, nil)
        }
    }

    /// Адрес свойства на главном элементе.
    private func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Читает значение свойства фиксированного размера.
    private func readValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
        var address = propertyAddress(selector, scope: scope, element: element)
        var storage = [UInt8](repeating: 0, count: MemoryLayout<T>.stride)
        var size = UInt32(storage.count)
        let status = storage.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(id, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return nil }
        return storage.withUnsafeBytes { $0.load(as: T.self) }
    }

    /// Записывает значение свойства.
    private func writeValue<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, _ value: T) -> Bool {
        var address = propertyAddress(selector, scope: scope, element: element)
        var value = value
        let size = UInt32(MemoryLayout<T>.stride)
        return withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(id, &address, 0, nil, size, pointer) == noErr
        }
    }
}

/// Колбэк CoreAudio без захвата контекста. Обновление интерфейса — на главной очереди.
private func audioHardwareChanged(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    AudioOutput.shared.enqueueRefresh()
    return noErr
}
