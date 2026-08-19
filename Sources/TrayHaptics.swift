import AppKit
import Foundation
import IOKit

/// Тактильный отклик трекпада (`TR-29`).
///
/// `NSHapticFeedbackManager` здесь молчит: QuickShot живёт как `.accessory`
/// (LSUIElement) и никогда не активен, а система отдаёт отклик активному
/// приложению. Ошибки при этом нет — вызов просто уходит в никуда. Поэтому
/// щелчок идёт напрямую в актуатор трекпада. Плата — приватные символы: в Mac
/// App Store такое приложение не пройдёт; QuickShot собирается локально.
///
/// Устройство для щелчка берётся ИЗ САМОГО СОБЫТИЯ, а не угадывается:
///
///     NSEvent → CGEvent → CGEventCopyIOHIDEvent → IOHIDEventGetSenderID
///     → это IORegistryEntryID узла AppleMultitouchDevice
///     → его свойство "Multitouch ID" → аргумент MTActuatorCreateFromDeviceID
///
/// Прежняя эвристика по кадрам касаний (`MTRegisterContactFrameCallback`)
/// снята: она промахивалась в инерции, когда пальцы уже сняты с трекпада, а
/// защёлка чаще всего срабатывает именно там. Кроме того, указатели из
/// `MTDeviceCreateList` меняются при каждом вызове, поэтому подписка на кадры
/// жила только для устройств первого списка — переподключившийся по Bluetooth
/// трекпад не давал кадров никогда.
///
/// ПРАВИЛО, оплаченное отладкой: на одно устройство в один момент — ровно один
/// открытый дескриптор. Второй дескриптор поверх живого встроенный трекпад
/// терпит, а внешний по Bluetooth отдаёт мёртвую сессию: удары по ней
/// отвечают `kIOReturnSuccess` и молчат. Код возврата успеха вообще НЕ
/// означает, что актуатор сработал — проверять только ощущением.
final class TrayHaptics: @unchecked Sendable {
    /// Волны актуатора: 1 — слабый щелчок, 2 — сильный (ощущение Force
    /// Touch), 3 — зуммер, 4/5/6 — тап от лёгкого к сильному. Остальные
    /// номера устройство отвергает.
    enum Pulse: Int32 {
        /// Посадка в защёлку: сильный щелчок.
        case firm = 2
        /// Выход из защёлки: слабый щелчок.
        case light = 1
    }

    static let shared = TrayHaptics()

    /// Журнал: единственный способ увидеть, какое устройство выбрано и дошёл
    /// ли до него импульс.
    nonisolated(unsafe) static var logSink: ((String) -> Void)?

    private typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpenFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ActuatorActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32) -> Int32
    private typealias ActuatorCloseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias CopyIOHIDEventFn = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias EventSenderIDFn = @convention(c) (CFTypeRef) -> UInt64

    /// Дескриптор устаревает — переоткрываем при следующем `arm()`.
    private static let freshness: TimeInterval = 1.5

    private struct Handle {
        let holder: AnyObject
        let ref: UnsafeMutableRawPointer
        let multitouchID: UInt64
        let openedAt: Date
    }

    private let queue = DispatchQueue(label: "io.quickshot.haptics", qos: .userInitiated)
    private let lock = NSLock()
    private var handles: [Handle] = []
    private var openedAt = Date.distantPast
    private var refreshing = false
    /// Соответствие «узел реестра → устройство multitouch». Строится публичным
    /// IOKit, обновляется при неизвестном отправителе (подключили трекпад).
    private var deviceByRegistryID: [UInt64: UInt64] = [:]

    private var create: ActuatorCreateFn?
    private var open: ActuatorOpenFn?
    private var actuate: ActuatorActuateFn?
    private var close: ActuatorCloseFn?
    private var copyIOHIDEvent: CopyIOHIDEventFn?
    private var eventSenderID: EventSenderIDFn?
    private var loaded = false

    private init() {}

    // MARK: устройство из события

    /// Трекпад, породивший событие. `nil`, если событие пришло не от трекпада
    /// (мышь: у неё нет `Multitouch ID`) или у события нет HID-нагрузки —
    /// часть событий синтезирует оконный сервер.
    func device(of event: NSEvent) -> UInt64? {
        loadSymbolsIfNeeded()
        lock.lock()
        let copyIOHIDEvent = self.copyIOHIDEvent
        let eventSenderID = self.eventSenderID
        lock.unlock()
        guard let copyIOHIDEvent, let eventSenderID,
              let cgEvent = event.cgEvent,
              let hidEvent = copyIOHIDEvent(cgEvent)?.takeRetainedValue() else { return nil }
        let senderID = eventSenderID(hidEvent)
        guard senderID != 0 else { return nil }
        if let known = lookup(registryID: senderID) { return known }
        // Незнакомый отправитель: возможно, трекпад подключили только что.
        rebuildDeviceMap()
        return lookup(registryID: senderID)
    }

    private func lookup(registryID: UInt64) -> UInt64? {
        lock.lock()
        let id = deviceByRegistryID[registryID]
        lock.unlock()
        return id
    }

    /// Перечисление трекпадов публичным IOKit: узлы `AppleMultitouchDevice`
    /// несут и идентификатор реестра (он же отправитель события), и
    /// `Multitouch ID` для актуатора. `MTDeviceCreateList` не нужен — а с ним
    /// уходит и риск висячих указателей.
    private func rebuildDeviceMap() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleMultitouchDevice"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var map: [UInt64: UInt64] = [:]
        var actuating: [UInt64] = []
        var report: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                  let multitouchID = numberProperty(service, "Multitouch ID") else { continue }
            map[registryID] = multitouchID
            let actuation = numberProperty(service, "ActuationSupported").map { $0 != 0 } ?? true
            if actuation { actuating.append(multitouchID) }
            let name = stringProperty(service, "Product") ?? "?"
            report.append("\(name)=\(multitouchID)\(actuation ? "" : " (без актуатора)")")
        }
        lock.lock()
        deviceByRegistryID = map
        lock.unlock()
        Self.logSink?("трекпады: [\(report.joined(separator: " | "))]")
        knownActuating = actuating
    }

    private var knownActuating: [UInt64] = []

    private func numberProperty(_ service: io_service_t, _ key: String) -> UInt64? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString,
                                                          kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return value.uint64Value
    }

    private func stringProperty(_ service: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString,
                                        kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    // MARK: щелчок

    /// Приготовиться: открыть дескрипторы, если устарели. Открытие внешнего
    /// трекпада по Bluetooth стоит десятки миллисекунд, поэтому идёт в фоне.
    func arm() {
        lock.lock()
        let stale = Date().timeIntervalSince(openedAt) > Self.freshness
        let busy = refreshing
        if stale && !busy { refreshing = true }
        lock.unlock()
        guard stale, !busy else { return }
        queue.async { [weak self] in self?.refresh() }
    }

    /// Щелчок в заданный трекпад. Без устройства (событие не принесло
    /// источник) импульс идёт во все — лучше щелчок не на том трекпаде, чем
    /// тишина.
    @discardableResult
    func click(_ pulse: Pulse, device: UInt64?) -> Bool {
        lock.lock()
        let current = handles
        let actuate = self.actuate
        lock.unlock()
        guard let actuate, !current.isEmpty else {
            Self.logSink?("щелчок: дескрипторов нет")
            arm()
            return false
        }
        var report: [String] = []
        var delivered = false
        for handle in current {
            guard device == nil || device == handle.multitouchID else {
                report.append("\(handle.multitouchID)=пропуск")
                continue
            }
            let status = actuate(handle.ref, pulse.rawValue, 0, 0, 0)
            let age = Int(Date().timeIntervalSince(handle.openedAt) * 1000)
            report.append("\(handle.multitouchID)=\(String(format: "0x%x", status))/\(age)мс")
            if status == 0 { delivered = true }
        }
        Self.logSink?("щелчок волна=\(pulse.rawValue) устройство=\(device.map(String.init) ?? "все") [\(report.joined(separator: " "))]")
        arm()
        return delivered
    }

    private func refresh() {
        loadSymbolsIfNeeded()
        lock.lock()
        let create = self.create
        let open = self.open
        let close = self.close
        // Старая сессия закрывается ДО открытия новой: два дескриптора на одно
        // устройство дают мёртвую сессию на Bluetooth-трекпаде.
        let previous = handles
        handles = []
        lock.unlock()
        for handle in previous { _ = close?(handle.ref) }

        if knownActuating.isEmpty { rebuildDeviceMap() }
        guard let create, let open else {
            lock.lock(); refreshing = false; lock.unlock()
            return
        }
        var fresh: [Handle] = []
        var report: [String] = []
        for multitouchID in knownActuating {
            guard let actuatorRef = create(multitouchID)?.takeRetainedValue() else {
                report.append("\(multitouchID)=нет актуатора")
                continue
            }
            let holder = actuatorRef as AnyObject
            let ref = unsafeBitCast(holder, to: UnsafeMutableRawPointer.self)
            let t0 = Date()
            let status = open(ref, 0)
            let cost = Int(Date().timeIntervalSince(t0) * 1000)
            report.append("\(multitouchID)=\(String(format: "0x%x", status))/\(cost)мс")
            guard status == 0 else { continue }
            fresh.append(Handle(holder: holder, ref: ref, multitouchID: multitouchID, openedAt: Date()))
        }
        lock.lock()
        handles = fresh
        openedAt = Date()
        refreshing = false
        lock.unlock()
        Self.logSink?("открыто устройств \(fresh.count): [\(report.joined(separator: " "))]")
    }

    private func loadSymbolsIfNeeded() {
        lock.lock()
        let already = loaded
        if !already { loaded = true }
        lock.unlock()
        guard !already else { return }
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                               RTLD_NOW),
              let pCreate = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let pOpen = dlsym(lib, "MTActuatorOpen"),
              let pActuate = dlsym(lib, "MTActuatorActuate"),
              let pClose = dlsym(lib, "MTActuatorClose") else { return }
        // Символы адресации живут в общем кэше: не нашлись — остаётся веер по
        // всем устройствам, а не падение.
        let pCopyHID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventCopyIOHIDEvent")
        let pSender = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetSenderID")
        lock.lock()
        create = unsafeBitCast(pCreate, to: ActuatorCreateFn.self)
        open = unsafeBitCast(pOpen, to: ActuatorOpenFn.self)
        actuate = unsafeBitCast(pActuate, to: ActuatorActuateFn.self)
        close = unsafeBitCast(pClose, to: ActuatorCloseFn.self)
        if let pCopyHID, let pSender {
            copyIOHIDEvent = unsafeBitCast(pCopyHID, to: CopyIOHIDEventFn.self)
            eventSenderID = unsafeBitCast(pSender, to: EventSenderIDFn.self)
        }
        lock.unlock()
        Self.logSink?("адресация по событию: \(pCopyHID != nil && pSender != nil ? "доступна" : "НЕДОСТУПНА")")
        rebuildDeviceMap()
    }
}
