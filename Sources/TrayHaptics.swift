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
/// ГЛАВНОЕ ПРАВИЛО (19.08.2026, оплачено долгой отладкой): на одно устройство
/// в один момент — РОВНО ОДИН открытый дескриптор. Пока приложение держало
/// сессию и открывало поверх неё вторую, встроенный трекпад это терпел, а
/// внешний Magic Trackpad по Bluetooth — нет: второе открытие занимало 438 мс
/// и возвращало мёртвую сессию, удары по которой отвечали успехом и молчали.
/// Отсюда «на встроенном щёлкает, на внешнем нет». После закрытия старой
/// сессии перед открытием новой то же открытие стоит 16-50 мс, и щелчок
/// доходит.
///
/// Замеры: открытие 8-50 мс (при соблюдении правила), удар по готовому
/// дескриптору доли миллисекунды. Открытие идёт в фоне по наведению на трей и
/// в начале жеста, щелчок бьёт по готовому — главный поток не ждёт.
///
/// Код возврата `kIOReturnSuccess` НЕ означает, что актуатор сработал: он
/// означает лишь, что вызов принят. Проверять ощущением.
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
    private typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    private typealias RegisterContactFn = @convention(c) (UnsafeMutableRawPointer, @escaping ContactCallback) -> Void
    private typealias DeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

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
    private var registerContact: RegisterContactFn?
    private var deviceStart: DeviceStartFn?
    private var loaded = false
    private var watching = false
    /// Список устройств удерживается живым, пока работает слежение: обратный
    /// вызов получает указатель на устройство, и освобождение списка сделало
    /// бы этот указатель висячим — падение вместо щелчка.
    private var watchedDevices: NSArray?

    /// Когда на устройстве последний раз лежали пальцы. Щёлкать должен тот
    /// трекпад, что под рукой: лежащий рядом на столе второй трекпад щёлкать
    /// не должен (приёмка 19.08.2026).
    private static let touchLock = NSLock()
    nonisolated(unsafe) private static var lastTouch: [UInt64: Date] = [:]
    /// Насколько свежим считается касание. Жест прокрутки идёт непрерывным
    /// потоком кадров, поэтому окно узкое: рука ушла с трекпада — щелчок туда
    /// больше не адресуется.
    private static let touchWindow: TimeInterval = 0.3

    private static func noteTouch(_ deviceID: UInt64) {
        touchLock.lock()
        lastTouch[deviceID] = Date()
        touchLock.unlock()
    }

    /// Устройство под рукой: тронутое ПОСЛЕДНИМ, один победитель. Окно
    /// «недавно тронутых» не годится — при переходе с трекпада на трекпад
    /// старый ещё считался тронутым, и щёлкали оба.
    private static func activeDevice() -> (id: UInt64, age: TimeInterval)? {
        touchLock.lock()
        let snapshot = lastTouch
        touchLock.unlock()
        let now = Date()
        guard let newest = snapshot.max(by: { $0.value < $1.value }) else { return nil }
        let age = now.timeIntervalSince(newest.value)
        return age <= touchWindow ? (newest.key, age) : nil
    }

    /// Возраст последнего касания устройства — для журнала.
    private static func touchAge(_ deviceID: UInt64) -> TimeInterval? {
        touchLock.lock()
        let stamp = lastTouch[deviceID]
        touchLock.unlock()
        return stamp.map { Date().timeIntervalSince($0) }
    }

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
        // ВРЕМЕННО: импульс идёт во все устройства. Адресный выбор (только
        // трекпад под рукой) технически работает — журнал это подтвердил, —
        // но обнажил другое явление: импульс не ощущается именно на том
        // трекпаде, которого касается рука, и ощущается на лежащем без дела.
        // Пока явление не изучено, поведение возвращено к рабочему: лучше
        // щелчок не на том трекпаде, чем тишина (приёмка 19.08.2026).
        let active = Self.activeDevice()
        var report: [String] = []
        var delivered = false
        for handle in current {
            let ageText = Self.touchAge(handle.deviceID).map { String(format: "%.0fмс", $0 * 1000) } ?? "нет"
            _ = active
            let status = actuate(handle.ref, pulse.rawValue, 0, 0, 0)
            let age = Int(Date().timeIntervalSince(handle.openedAt) * 1000)
            report.append("\(handle.deviceID)=\(String(format: "0x%x", status))/\(age)мс(касание \(ageText))")
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
            startWatching(device: device, deviceID: deviceID)
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
        if registerContact != nil, deviceStart != nil, !watching {
            watching = true
            watchedDevices = list
        }
        lock.unlock()
        Self.logSink?("открыто устройств \(fresh.count): [\(report.joined(separator: " "))]")
    }

    /// Поднять слежение за касаниями: система зовёт обратный вызов на каждый
    /// кадр касаний, по нему и видно, какой трекпад сейчас под рукой.
    /// Поднимается один раз на процесс — повторный старт устройства ничего не
    /// даёт, а лишние подписки только грузят систему.
    private func startWatching(device: UnsafeMutableRawPointer, deviceID: UInt64) {
        lock.lock()
        let already = watching
        let registerContact = self.registerContact
        let deviceStart = self.deviceStart
        lock.unlock()
        guard !already, let registerContact, let deviceStart else { return }
        // Обратный вызов — сишная функция без контекста, поэтому устройство
        // опознаётся по тому же смещению в структуре, что и при открытии.
        let callback: ContactCallback = { device, _, fingers, _, _ in
            guard fingers > 0, let device else { return }
            var deviceID: UInt64 = 0
            withUnsafeMutableBytes(of: &deviceID) { buffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(
                    start: device.advanced(by: TrayHaptics.deviceIDOffset),
                    count: MemoryLayout<UInt64>.size))
            }
            TrayHaptics.noteTouch(deviceID)
        }
        registerContact(device, callback)
        deviceStart(device, 0)
        Self.logSink?("слежение за касаниями поднято: \(deviceID)")
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
        let pRegister = dlsym(lib, "MTRegisterContactFrameCallback")
        let pStart = dlsym(lib, "MTDeviceStart")
        lock.lock()
        if let pRegister, let pStart {
            registerContact = unsafeBitCast(pRegister, to: RegisterContactFn.self)
            deviceStart = unsafeBitCast(pStart, to: DeviceStartFn.self)
        }
        createList = unsafeBitCast(pCreateList, to: CreateListFn.self)
        create = unsafeBitCast(pCreate, to: ActuatorCreateFn.self)
        open = unsafeBitCast(pOpen, to: ActuatorOpenFn.self)
        actuate = unsafeBitCast(pActuate, to: ActuatorActuateFn.self)
        close = unsafeBitCast(pClose, to: ActuatorCloseFn.self)
        lock.unlock()
    }
}
