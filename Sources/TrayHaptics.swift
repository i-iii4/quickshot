import AppKit
import Foundation

/// Тактильный отклик трекпада (`TR-29`).
///
/// `NSHapticFeedbackManager` здесь молчит: QuickShot живёт как `.accessory`
/// (LSUIElement) и никогда не активен, а система отдаёт актуатор активному
/// приложению. Вызов уходит в никуда без ошибки, поэтому щелчок идёт прямым
/// путём через MultitouchSupport. Плата — приватный фреймворк: в Mac App
/// Store такое приложение не пройдёт; QuickShot собирается локально.
///
/// Замеры 19.08.2026 (оба трекпада пользователя):
/// - открытие актуатора: встроенный 21 мс, внешний по Bluetooth 438 мс;
/// - удар по открытому дескриптору: 0.2 мс.
///
/// Отсюда вся конструкция: открывать на каждый щелчок нельзя (438 мс убили бы
/// кадр), держать открытым с запуска — тоже (дескриптор внешнего трекпада к
/// моменту жеста протухает, и удары уходят в пустоту, возвращая успех: щелчки
/// чувствовались только на встроенном). Поэтому дескрипторы обновляются
/// ЗАРАНЕЕ и в фоне — по наведению на трей и в начале жеста, когда рука на
/// трекпаде и устройство заведомо не спит, — а сам щелчок бьёт по готовому.
final class TrayHaptics: @unchecked Sendable {
    /// Волны актуатора (известны из разбора): 1 — слабый щелчок, 2 — сильный
    /// щелчок с ощущением Force Touch, 3 — зуммер, 4/5/6 — тап от лёгкого к
    /// сильному. Прочие номера устройство отвергает.
    enum Pulse: Int32 {
        /// Посадка в защёлку: сильный щелчок.
        case firm = 2
        /// Выход из защёлки: слабый щелчок.
        case light = 1
    }

    static let shared = TrayHaptics()

    // Сигнатуры критичны: на arm64 целые аргументы идут в целочисленных
    // регистрах, а `Float` — в регистрах с плавающей точкой. Ошибка в
    // объявлении не даёт ошибки вызова: актуатор возвращает успех и молчит.
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpenFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ActuatorActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32) -> Int32
    private typealias ActuatorCloseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    /// Идентификатор устройства лежит в непрозрачной структуре `MTDevice` по
    /// известному смещению: штатный `MTDeviceGetDeviceID` на Apple Silicon
    /// имеет нестабильное соглашение вызова.
    private static let deviceIDOffset = 64
    /// Дескриптор старше этого срока обновляется при следующем `arm()`.
    private static let freshness: TimeInterval = 1.5

    private struct Handle {
        let holder: AnyObject
        let ref: UnsafeMutableRawPointer
        let deviceID: UInt64
        let openedAt: Date
    }

    private let queue = DispatchQueue(label: "io.quickshot.haptics", qos: .userInitiated)
    private let lock = NSLock()
    private var handles: [Handle] = []
    private var openedAt = Date.distantPast
    private var refreshing = false

    private var createList: CreateListFn?
    private var create: ActuatorCreateFn?
    private var open: ActuatorOpenFn?
    private var actuate: ActuatorActuateFn?
    private var close: ActuatorCloseFn?
    private var loaded = false

    /// Журнал открытий и ударов: единственный способ узнать, дошёл ли импульс
    /// до конкретного устройства. Код возврата успеха о срабатывании
    /// актуатора не говорит, но отсутствие устройства в списке — говорит.
    nonisolated(unsafe) static var logSink: ((String) -> Void)?

    private init() {}

    /// Приготовиться к щелчку: обновить дескрипторы, если устарели. Открытие
    /// внешнего трекпада по Bluetooth стоит сотни миллисекунд, поэтому идёт в
    /// фоне; вызов возвращается мгновенно.
    func arm() {
        lock.lock()
        let stale = Date().timeIntervalSince(openedAt) > Self.freshness
        let busy = refreshing
        if stale && !busy { refreshing = true }
        lock.unlock()
        guard stale, !busy else { return }
        queue.async { [weak self] in self?.refresh() }
    }

    /// Один щелчок во все трекпады с актуатором: событие прокрутки не
    /// сообщает, какой из них под рукой, а незанятый трекпад щелчка не выдаёт.
    @discardableResult
    func click(_ pulse: Pulse) -> Bool {
        lock.lock()
        let current = handles
        let actuate = self.actuate
        lock.unlock()
        guard let actuate, !current.isEmpty else {
            Self.logSink?("щелчок: дескрипторов нет")
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            arm()
            return false
        }
        var report: [String] = []
        var delivered = false
        for handle in current {
            let status = actuate(handle.ref, pulse.rawValue, 0, 0, 0)
            let age = Int(Date().timeIntervalSince(handle.openedAt) * 1000)
            report.append("\(handle.deviceID)=\(String(format: "0x%x", status))/\(age)мс")
            if status == 0 { delivered = true }
        }
        Self.logSink?("щелчок волна=\(pulse.rawValue) [\(report.joined(separator: " "))]")
        arm()
        return delivered
    }

    private func refresh() {
        loadSymbolsIfNeeded()
        lock.lock()
        let createList = self.createList
        let create = self.create
        let open = self.open
        let close = self.close
        // Старые сессии закрываются ДО открытия новых: два дескриптора на одно
        // устройство могут конфликтовать за исключительный доступ.
        let previous = handles
        handles = []
        lock.unlock()
        for handle in previous { _ = close?(handle.ref) }

        guard let createList, let create, let open,
              let list = createList()?.takeRetainedValue() as NSArray? else {
            lock.lock(); refreshing = false; lock.unlock()
            Self.logSink?("обновление: символы или список устройств недоступны")
            return
        }
        var fresh: [Handle] = []
        var report: [String] = []
        for element in list {
            let device = unsafeBitCast(element as AnyObject, to: UnsafeMutableRawPointer.self)
            var deviceID: UInt64 = 0
            withUnsafeMutableBytes(of: &deviceID) { buffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(
                    start: device.advanced(by: Self.deviceIDOffset),
                    count: MemoryLayout<UInt64>.size))
            }
            guard let actuatorRef = create(deviceID)?.takeRetainedValue() else {
                report.append("\(deviceID)=нет актуатора")
                continue
            }
            let holder = actuatorRef as AnyObject
            let ref = unsafeBitCast(holder, to: UnsafeMutableRawPointer.self)
            let t0 = Date()
            let status = open(ref, 0)
            let cost = Int(Date().timeIntervalSince(t0) * 1000)
            report.append("\(deviceID)=\(String(format: "0x%x", status))/\(cost)мс")
            guard status == 0 else { continue }
            fresh.append(Handle(holder: holder, ref: ref, deviceID: deviceID, openedAt: Date()))
        }
        lock.lock()
        handles = fresh
        openedAt = Date()
        refreshing = false
        lock.unlock()
        Self.logSink?("открыто устройств \(fresh.count): [\(report.joined(separator: " "))]")
    }

    private func loadSymbolsIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                               RTLD_NOW),
              let pCreateList = dlsym(lib, "MTDeviceCreateList"),
              let pCreate = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let pOpen = dlsym(lib, "MTActuatorOpen"),
              let pActuate = dlsym(lib, "MTActuatorActuate"),
              let pClose = dlsym(lib, "MTActuatorClose") else { return }
        lock.lock()
        createList = unsafeBitCast(pCreateList, to: CreateListFn.self)
        create = unsafeBitCast(pCreate, to: ActuatorCreateFn.self)
        open = unsafeBitCast(pOpen, to: ActuatorOpenFn.self)
        actuate = unsafeBitCast(pActuate, to: ActuatorActuateFn.self)
        close = unsafeBitCast(pClose, to: ActuatorCloseFn.self)
        lock.unlock()
    }
}
