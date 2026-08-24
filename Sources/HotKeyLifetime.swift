import Carbon.HIToolbox

/// Снимает регистрацию горячей клавиши и её обработчик. Безопасно вызывать
/// многократно; обе горячие клавиши QuickShot — съёмка и Escape в сессии —
/// снимались этим кодом дословно.
func releaseHotKey(_ hotKeyRef: inout EventHotKeyRef?, _ handlerRef: inout EventHandlerRef?) {
    if let hotKeyRef {
        UnregisterEventHotKey(hotKeyRef)
    }
    hotKeyRef = nil
    if let handlerRef {
        RemoveEventHandler(handlerRef)
    }
    handlerRef = nil
}
