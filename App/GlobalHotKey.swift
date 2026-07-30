import Carbon.HIToolbox
import Foundation

final class GlobalHotKey: @unchecked Sendable {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @MainActor @Sendable () -> Void
    private(set) var registrationStatus: OSStatus = OSStatus(eventInternalErr)

    var isRegistered: Bool {
        registrationStatus == noErr && hotKey != nil
    }

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let instance = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { instance.action() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        guard handlerStatus == noErr else {
            registrationStatus = handlerStatus
            return
        }

        let identifier = EventHotKeyID(signature: Self.signature("LDCT"), id: 1)
        registrationStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), identifier,
                                                 GetApplicationEventTarget(), 0, &hotKey)
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private static func signature(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }
}
