import Carbon.HIToolbox

/// Session-scoped Escape registration that works while QuickShot deliberately
/// stays inactive. Carbon observes only this key and requires no input monitor.
@MainActor
final class SessionEscapeHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onEscape: (() -> Void)?

    private let signature: OSType = 0x5145_7363 // 'QEsc'
    private let keyID: UInt32 = 1

    @discardableResult
    func register(_ handler: @escaping () -> Void) -> Bool {
        unregister()
        onEscape = handler

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(),
                                  sessionEscapeHandler,
                                  1,
                                  &spec,
                                  context,
                                  &handlerRef) == noErr else {
            unregister()
            return false
        }

        let identifier = EventHotKeyID(signature: signature, id: keyID)
        guard RegisterEventHotKey(UInt32(kVK_Escape),
                                  0,
                                  identifier,
                                  GetApplicationEventTarget(),
                                  0,
                                  &hotKeyRef) == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        releaseHotKey(&hotKeyRef, &handlerRef)
        onEscape = nil
    }

    fileprivate func fire(_ identifier: EventHotKeyID) -> Bool {
        guard identifier.signature == signature, identifier.id == keyID else { return false }
        onEscape?()
        return true
    }

}

private func sessionEscapeHandler(_ next: EventHandlerCallRef?,
                                  _ event: EventRef?,
                                  _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &identifier)
    guard status == noErr else { return status }
    let owner = Unmanaged<SessionEscapeHotKey>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        owner.fire(identifier) ? noErr : OSStatus(eventNotHandledErr)
    }
}
