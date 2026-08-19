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
    enum Pulse: Int32 {
        /// Посадка в защёлку: плотный щелчок.
        case firm = 15
        /// Выход из защёлки: щелчок полегче.
        case light = 3
    }

    static let shared = TrayHaptics()

    private typealias CreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias GetDeviceIDFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias ActuatorCreateFn = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOpenFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ActuatorActuateFn = @convention(c) (UnsafeMutableRawPointer, Int32, UInt32, Float, Float) -> Int32

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

    private func prepareIfNeeded() {
        guard !prepared else { return }
        prepared = true
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                               RTLD_NOW),
              let pCreateList = dlsym(lib, "MTDeviceCreateList"),
              let pGetID = dlsym(lib, "MTDeviceGetDeviceID"),
              let pCreate = dlsym(lib, "MTActuatorCreateFromDeviceID"),
              let pOpen = dlsym(lib, "MTActuatorOpen"),
              let pActuate = dlsym(lib, "MTActuatorActuate") else { return }

        let createList = unsafeBitCast(pCreateList, to: CreateListFn.self)
        let getID = unsafeBitCast(pGetID, to: GetDeviceIDFn.self)
        let create = unsafeBitCast(pCreate, to: ActuatorCreateFn.self)
        let open = unsafeBitCast(pOpen, to: ActuatorOpenFn.self)
        actuate = unsafeBitCast(pActuate, to: ActuatorActuateFn.self)

        guard let list = createList()?.takeRetainedValue() as NSArray? else { return }
        for element in list {
            let device = unsafeBitCast(element as AnyObject, to: UnsafeMutableRawPointer.self)
            var deviceID: UInt64 = 0
            guard getID(device, &deviceID) == 0,
                  let actuatorRef = create(deviceID)?.takeRetainedValue() else { continue }
            let actuator = actuatorRef as AnyObject
            let ref = unsafeBitCast(actuator, to: UnsafeMutableRawPointer.self)
            // Трекпады без Force Touch и прочие multitouch-устройства просто
            // не открываются — они молча выпадают из списка.
            if open(ref) == 0 { actuators.append(actuator) }
        }
    }
}
