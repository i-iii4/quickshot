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
    /// Дескриптор старше этого срока считается протухшим.
    private static let freshness: TimeInterval = 2

    private struct Handle {
        let holder: AnyObject
        let ref: UnsafeMutableRawPointer
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

    private init() {}

    /// Приготовиться к щелчку: обновить дескрипторы, если они устарели.
    /// Возвращается немедленно — открытие идёт в фоне. Звать там, где рука
    /// только подходит к делу: наведение на трей, начало жеста.
    func prepare() {
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
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            prepare()
            return false
        }
        var delivered = false
        for handle in current where actuate(handle.ref, pulse.rawValue, 0, 0, 0) == 0 {
            delivered = true
        }
        // Следующий щелчок должен застать свежие дескрипторы: за жестом обычно
        // идёт ещё один.
        prepare()
        return delivered
    }

    private func refresh() {
        loadSymbolsIfNeeded()
        guard let createList, let create, let open, let close,
              let list = createList()?.takeRetainedValue() as NSArray? else {
            lock.lock(); refreshing = false; lock.unlock()
            return
        }
        var fresh: [Handle] = []
        for element in list {
            let device = unsafeBitCast(element as AnyObject, to: UnsafeMutableRawPointer.self)
            var deviceID: UInt64 = 0
            withUnsafeMutableBytes(of: &deviceID) { buffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(
                    start: device.advanced(by: Self.deviceIDOffset),
                    count: MemoryLayout<UInt64>.size))
            }
            guard let actuatorRef = create(deviceID)?.takeRetainedValue() else { continue }
            let holder = actuatorRef as AnyObject
            let ref = unsafeBitCast(holder, to: UnsafeMutableRawPointer.self)
            // Устройства без актуатора просто не открываются.
            guard open(ref, 0) == 0 else { continue }
            fresh.append(Handle(holder: holder, ref: ref))
        }
        lock.lock()
        let previous = handles
        handles = fresh
        openedAt = Date()
        refreshing = false
        lock.unlock()
        // Старые сессии закрываются ПОСЛЕ подмены: щелчок, пришедший в этот
        // момент, бьёт по новым дескрипторам, а не по закрываемым.
        for handle in previous { _ = close(handle.ref) }
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
