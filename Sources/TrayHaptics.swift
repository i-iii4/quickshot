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
        /// Выход из защёлки: средний тап — другой характер, чем у посадки, но
        /// ощутимый на обоих трекпадах. Слабый щелчок (волна 1) на встроенном
        /// актуаторе ниже порога ощущения: журнал показывал успешную доставку
        /// свежей сессией, а рука ничего не чувствовала (приёмка 19.08.2026).
        case light = 5
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

    private struct Handle {
        let holder: AnyObject
        let ref: UnsafeMutableRawPointer
        let multitouchID: UInt64
        let openedAt: Date
        /// Сколько стоило открытие. Дешёвое устройство переоткрывается на
        /// каждый удар, дорогое живёт с удержанной сессией.
        let openCost: TimeInterval
    }

    /// Граница дешевизны открытия. Встроенный трекпад открывается за 7-22 мс,
    /// внешний по Bluetooth — за 30-500 мс.
    private static let cheapOpen: TimeInterval = 0.04

    private let queue = DispatchQueue(label: "io.quickshot.haptics", qos: .userInitiated)
    private let lock = NSLock()
    private var handles: [Handle] = []
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

    /// Приготовиться: открыть недостающие сессии. Открытых НЕ трогаем.
    ///
    /// Переоткрытие по таймеру было моей самодеятельностью и стоило функции:
    /// сессия, переоткрытая под лежащим пальцем, у встроенного трекпада
    /// молчит — система в этот момент пользуется его актуатором сама. Отсюда
    /// «на встроенном щёлкает один раз, дальше только внешний» (приёмка
    /// 19.08.2026). Плюс щелчок, попавший в окно между закрытием и открытием,
    /// терялся вовсе. Сессия открывается один раз и живёт; переоткрывается
    /// только та, чей удар вернул ошибку.
    func arm() {
        lock.lock()
        let missing = knownActuating.isEmpty
            || handles.count < knownActuating.count
        let busy = refreshing
        if missing && !busy { refreshing = true }
        lock.unlock()
        guard missing, !busy else { return }
        queue.async { [weak self] in self?.openMissing() }
    }

    /// Щелчок в заданный трекпад. Без устройства (событие не принесло
    /// источник) импульс идёт во все — лучше щелчок не на том трекпаде, чем
    /// тишина.
    /// Удар идёт на своём потоке: у дешёвого устройства сессия перед ударом
    /// открывается заново (удержанная сессия у встроенного трекпада молчит —
    /// приёмка 19.08.2026), у дорогого бьём по удержанной. Главный поток не
    /// ждёт ни того, ни другого.
    func click(_ pulse: Pulse, device: UInt64?) {
        queue.async { [weak self] in self?.deliver(pulse, device: device) }
    }

    private func deliver(_ pulse: Pulse, device: UInt64?) {
        lock.lock()
        let current = handles
        let actuate = self.actuate
        lock.unlock()
        guard let actuate, !current.isEmpty else {
            Self.logSink?("щелчок: сессий нет")
            openMissing()
            return
        }
        var report: [String] = []
        for handle in current {
            guard device == nil || device == handle.multitouchID else {
                report.append("\(handle.multitouchID)=пропуск")
                continue
            }
            // Дешёвое устройство бьётся по свежей сессии — ровно так, как это
            // делает эталонная утилита, у которой встроенный трекпад щёлкает.
            let target = handle.openCost <= Self.cheapOpen ? reopen(handle) ?? handle : handle
            let status = actuate(target.ref, pulse.rawValue, 0, 0, 0)
            let age = Int(Date().timeIntervalSince(target.openedAt) * 1000)
            report.append("\(handle.multitouchID)=\(String(format: "0x%x", status))/\(age)мс")
            if status != 0 { dropHandle(handle.multitouchID) }
        }
        Self.logSink?("щелчок волна=\(pulse.rawValue) устройство=\(device.map(String.init) ?? "все") [\(report.joined(separator: " "))]")
    }

    /// Закрыть сессию и открыть заново — соблюдая правило «один дескриптор на
    /// устройство»: сначала закрытие, потом открытие.
    private func reopen(_ handle: Handle) -> Handle? {
        lock.lock()
        let create = self.create
        let open = self.open
        let close = self.close
        handles.removeAll { $0.multitouchID == handle.multitouchID }
        lock.unlock()
        _ = close?(handle.ref)
        guard let create, let open,
              let actuatorRef = create(handle.multitouchID)?.takeRetainedValue() else { return nil }
        let holder = actuatorRef as AnyObject
        let ref = unsafeBitCast(holder, to: UnsafeMutableRawPointer.self)
        let t0 = Date()
        guard open(ref, 0) == 0 else { return nil }
        let fresh = Handle(holder: holder, ref: ref, multitouchID: handle.multitouchID,
                           openedAt: Date(), openCost: Date().timeIntervalSince(t0))
        lock.lock()
        handles.append(fresh)
        lock.unlock()
        return fresh
    }

    /// Закрыть и забыть сессию устройства: следующий `arm()` откроет её
    /// заново. Правило «один открытый дескриптор на устройство» соблюдается —
    /// сначала закрываем, потом открываем.
    private func dropHandle(_ multitouchID: UInt64) {
        lock.lock()
        let doomed = handles.filter { $0.multitouchID == multitouchID }
        handles.removeAll { $0.multitouchID == multitouchID }
        let close = self.close
        lock.unlock()
        for handle in doomed { _ = close?(handle.ref) }
        Self.logSink?("сессия \(multitouchID) закрыта после ошибки")
    }

    /// Открыть сессии для устройств, у которых их ещё нет. Живые сессии не
    /// трогаются вовсе.
    private func openMissing() {
        loadSymbolsIfNeeded()
        if knownActuating.isEmpty { rebuildDeviceMap() }
        lock.lock()
        let create = self.create
        let open = self.open
        let alive = Set(handles.map(\.multitouchID))
        lock.unlock()
        guard let create, let open else {
            lock.lock(); refreshing = false; lock.unlock()
            return
        }
        var opened: [Handle] = []
        var report: [String] = []
        for multitouchID in knownActuating where !alive.contains(multitouchID) {
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
            opened.append(Handle(holder: holder, ref: ref, multitouchID: multitouchID,
                                 openedAt: Date(),
                                 openCost: Date().timeIntervalSince(t0)))
        }
        lock.lock()
        handles.append(contentsOf: opened)
        refreshing = false
        let total = handles.count
        lock.unlock()
        if !report.isEmpty {
            Self.logSink?("открыто сессий +\(opened.count) (всего \(total)): [\(report.joined(separator: " "))]")
        }
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
