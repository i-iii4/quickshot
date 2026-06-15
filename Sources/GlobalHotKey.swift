import AppKit
import Carbon.HIToolbox

/// Глобальный системный хоткей через Carbon RegisterEventHotKey.
///
/// Почему Carbon, а не NSEvent/CGEventTap: это единственный механизм, не требующий
/// никаких разрешений. NSEvent.addGlobalMonitorForEvents(.keyDown) молча требует
/// Accessibility и без неё просто не срабатывает; CGEventTap — ещё тяжелее.
/// RegisterEventHotKey подписывается только на ОДНУ конкретную комбинацию, поэтому
/// система не считает его клавиатурным шпионом и не запрашивает прав.
///
/// Важно для macOS 15/26: комбинация обязана содержать Command или Control (не только
/// Shift/Option), иначе RegisterEventHotKey вернёт -9868. ⌘⇧4 это условие выполняет.
final class GlobalHotKey {

    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private let signature: OSType = 0x5153_6874   // 'QSht'
    private let keyID: UInt32 = 1

    private init() {}

    /// По умолчанию ⌘⇧4. Регистрировать на главном потоке внутри работающего
    /// главного run loop (applicationDidFinishLaunching это обеспечивает).
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_4),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  handler: @escaping () -> Void) {

        unregister()                 // идемпотентно
        onTrigger = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1, &spec,
            selfPtr,
            &handlerRef)

        guard installStatus == noErr else {
            NSLog("QuickShot: InstallEventHandler не удался: \(installStatus)")
            return
        }

        let hkID = EventHotKeyID(signature: signature, id: keyID)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // -9868 == eventInternalErr -> комбинация только из Shift/Option. Добавьте Cmd/Ctrl.
            NSLog("QuickShot: RegisterEventHotKey не удался: \(status)")
            unregister()
        } else {
            NSLog("QuickShot: хоткей зарегистрирован (⌘⇧4)")
        }
    }

    /// Безопасно вызывать многократно; вызывать при завершении.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        onTrigger = nil
    }

    fileprivate func fire(_ id: EventHotKeyID) {
        guard id.signature == signature, id.id == keyID else { return }
        // Колбэк приходит на главном потоке, но хоп через main.async гарантирует
        // корректный контекст для последующей работы с UI.
        DispatchQueue.main.async { [weak self] in self?.onTrigger?() }
    }

    deinit { unregister() }
}

/// C-совместимый колбэк. Глобальная функция без захвата конвертируется в указатель
/// на C-функцию; контекст Swift передаётся через userData как Unmanaged self.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var firedID = EventHotKeyID()
    let err = GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &firedID)
    guard err == noErr else { return err }

    let manager = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    manager.fire(firedID)
    return noErr
}
