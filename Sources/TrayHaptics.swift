import AppKit
import Foundation

/// Тактильный отклик трекпада (`TR-29`).
///
/// `NSHapticFeedbackManager` в этом приложении молчит: QuickShot живёт как
/// `.accessory` (LSUIElement) и никогда не становится активным, а его панели
/// не активирующие — система отдаёт актуатор активному приложению, и вызов
/// уходит в никуда. Ошибки при этом нет: `perform` ничего не возвращает.
///
/// Измерено зондом 19.08.2026: из того же фонового процесса прямой актуатор
/// MultitouchSupport открывается и срабатывает с кодом `kIOReturnSuccess` на
/// обоих устройствах. Поэтому щелчок идёт прямым путём, а публичный API
/// остаётся запасным.
///
/// Плата за это — приватный фреймворк: в Mac App Store такое приложение не
/// пройдёт. QuickShot собирается локально, поэтому цена приемлема.
@MainActor
final class TrayHaptics {
    /// Идентификаторы импульсов подобраны эмпирически: у актуатора нет
    /// публичной таблицы, известен лишь диапазон рабочих значений.
    /// Волны актуатора (известны из разбора): 1 — слабый щелчок, 2 — сильный
    /// щелчок с ощущением Force Touch, 3 — зуммер, 4/5/6 — тап от лёгкого к
    /// сильному, 15/16 — глухой удар.
    enum Pulse: Int32 {
        /// Посадка в защёлку: сильный щелчок.
        case firm = 2
        /// Выход из защёлки: слабый щелчок.
        case light = 1
    }

    static let shared = TrayHaptics()

    // Сигнатуры критичны: на arm64 целые аргументы едут в целочисленных
    // регистрах, а Float — в регистрах с плавающей точкой. Объявив последние
    // два параметра `Float`, я отправлял их не в те регистры, а целочисленные
    // получали мусор; вызов при этом возвращал `kIOReturnSuccess` и молчал.
    // `MTActuatorOpen` принимает ВТОРЫМ аргументом флаги — без него регистр
    // тоже содержал мусор.
    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpenFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias ActuatorActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, UInt32, UInt32) -> Int32
    /// Идентификатор устройства лежит в непрозрачной структуре `MTDevice` по
    /// известному смещению. Штатный `MTDeviceGetDeviceID` на Apple Silicon
    /// имеет нестабильное соглашение вызова и отдаёт мусор.
    private static let deviceIDOffset = 64

    private var actuate: ActuatorActuateFn?
    /// Открытые актуаторы удерживаются живыми: открытие на каждый щелчок
    /// добавляло бы задержку к моменту, который обязан совпасть с кадром.
    private var actuators: [AnyObject] = []
    private var prepared = false

    private init() {}

    /// Один щелчок. Молча уходит в публичный API, если прямой путь недоступен.
    @discardableResult
    func click(_ pulse: Pulse) -> Bool {
        prepareIfNeeded()
        guard let actuate, !actuators.isEmpty else {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return false
        }
        var delivered = false
        for actuator in actuators {
            let ref = unsafeBitCast(actuator, to: UnsafeMutableRawPointer.self)
            if actuate(ref, pulse.rawValue, 0, 0, 0) == 0 { delivered = true }
        }
        if !delivered {
            // Устройство могло отключиться: следующий щелчок соберёт список
            // заново.
            prepared = false
            actuators.removeAll()
        }
        return delivered
    }

    #if DEBUG_HAPTICS
    /// Прогон конкретной волны: ощущение проверяется только пальцем.
    @discardableResult
    func debugActuate(_ wave: Int32) -> Bool {
        prepareIfNeeded()
        guard let actuate, !actuators.isEmpty else { return false }
        var ok = false
        for actuator in actuators {
            let ref = unsafeBitCast(actuator, to: UnsafeMutableRawPointer.self)
            if actuate(ref, wave, 0, 0, 0) == 0 { ok = true }
        }
        return ok
    }
    #endif

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                               RTLD_NOW),
              let pCreateList = dlsym(lib, "MTDeviceCreateList"),
              let pCreate = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let pOpen = dlsym(lib, "MTActuatorOpen"),
              let pActuate = dlsym(lib, "MTActuatorActuate") else { return }

        let createList = unsafeBitCast(pCreateList, to: CreateListFn.self)
        let create = unsafeBitCast(pCreate, to: ActuatorCreateFn.self)
        let open = unsafeBitCast(pOpen, to: ActuatorOpenFn.self)
        actuate = unsafeBitCast(pActuate, to: ActuatorActuateFn.self)

        guard let list = createList()?.takeRetainedValue() as NSArray? else { return }
        for element in list {
            let device = unsafeBitCast(element as AnyObject, to: UnsafeMutableRawPointer.self)
            var deviceID: UInt64 = 0
            withUnsafeMutableBytes(of: &deviceID) { buffer in
                buffer.copyMemory(from: UnsafeRawBufferPointer(
                    start: device.advanced(by: Self.deviceIDOffset),
                    count: MemoryLayout<UInt64>.size))
            }
            guard let actuatorRef = create(deviceID)?.takeRetainedValue() else { continue }
            let actuator = actuatorRef as AnyObject
            let ref = unsafeBitCast(actuator, to: UnsafeMutableRawPointer.self)
            // Устройства без Force Touch просто не открываются — они молча
            // выпадают из списка.
            if open(ref, 0) == 0 { actuators.append(actuator) }
        }
    }
}
