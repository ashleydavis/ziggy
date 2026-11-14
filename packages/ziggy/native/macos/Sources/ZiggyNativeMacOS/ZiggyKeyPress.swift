//
// Presses and releases a key through AppKit's own event dispatch, for the remote control's press-key command: the events are posted to
// the application's queue, so the key takes the path a user's does, through AppKit and the web view. AppKit hands a key event only to
// the key window of the active application, so the press makes the app active and its window key first.
//

import AppKit
import Carbon.HIToolbox
import CZiggy
import WebKit

// Presses and releases a key written in Ziggy's shortcut syntax.
enum ZiggyKeyPress {
    // The subtype of the application-defined event that marks the end of the press's queue.
    private static let sentinelSubtype = Int16(0x5A47)

    // The key code of each of the core's named keys that has no character, from Carbon's constants.
    private static let namedKeyCodes: [String: Int] = [
        "up": kVK_UpArrow,
        "down": kVK_DownArrow,
        "left": kVK_LeftArrow,
        "right": kVK_RightArrow,
        "home": kVK_Home,
        "end": kVK_End,
        "pageup": kVK_PageUp,
        "pagedown": kVK_PageDown,
        "delete": kVK_ForwardDelete,
        "backspace": kVK_Delete,
        "enter": kVK_Return,
        "tab": kVK_Tab,
        "escape": kVK_Escape,
        "space": kVK_Space,
        "f1": kVK_F1,
        "f2": kVK_F2,
        "f3": kVK_F3,
        "f4": kVK_F4,
        "f5": kVK_F5,
        "f6": kVK_F6,
        "f7": kVK_F7,
        "f8": kVK_F8,
        "f9": kVK_F9,
        "f10": kVK_F10,
        "f11": kVK_F11,
        "f12": kVK_F12,
        "f13": kVK_F13,
        "f14": kVK_F14,
        "f15": kVK_F15,
        "f16": kVK_F16,
        "f17": kVK_F17,
        "f18": kVK_F18,
        "f19": kVK_F19,
        "f20": kVK_F20,
    ]

    // Presses and releases the key, and calls the completion with a reason when it cannot, or nil once the app's queue has delivered it.
    static func press(_ key: String, webView: WKWebView, completion: @escaping (String?) -> Void) {
        var accelerator = ziggy_accelerator()
        let parsed = key.withCString { pointer in
            ziggy_parse_accelerator(pointer, key.utf8.count, &accelerator)
        }
        if !parsed {
            completion("the native app cannot press \(key)")
            return
        }
        let keyName = withUnsafeBytes(of: accelerator.key) { raw -> String in
            return String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        var flags: NSEvent.ModifierFlags = []
        if accelerator.modifiers & UInt32(ZIGGY_MOD_CTRL) != 0 {
            flags.insert(.control)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_SHIFT) != 0 {
            flags.insert(.shift)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_ALT) != 0 {
            flags.insert(.option)
        }
        if accelerator.modifiers & UInt32(ZIGGY_MOD_META) != 0 {
            flags.insert(.command)
        }

        guard let window = webView.window else {
            completion("the web view has no window")
            return
        }
        guard let (keyCode, shiftForCharacter) = keyCodeAndShift(for: keyName, key: key) else {
            completion("the keyboard has no key for \(key)")
            return
        }
        var pressFlags = flags
        if shiftForCharacter {
            pressFlags.insert(.shift)
        }
        let keyCodeValue = UInt16(keyCode)

        let layout: Data
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            completion("the keyboard layout has no key table")
            return
        }
        layout = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())

        guard let characters = character(for: keyCodeValue, layout: layout, flags: pressFlags, keyboardType: keyboardType),
              let charactersIgnoringModifiers = character(for: keyCodeValue, layout: layout, flags: [], keyboardType: keyboardType) else {
            completion("the keyboard has no key for \(key)")
            return
        }

        if !NSApp.isActive || !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            guard event.subtype == ZiggyKeyPress.sentinelSubtype else {
                return event
            }
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
            completion(nil)
            return nil
        }

        let windowNumber = window.windowNumber
        let timestamp = ProcessInfo.processInfo.systemUptime
        var downFlags: NSEvent.ModifierFlags = []
        for (code, flag) in [(kVK_Control, NSEvent.ModifierFlags.control), (kVK_Shift, .shift), (kVK_Option, .option), (kVK_Command, .command)] {
            guard pressFlags.contains(flag) else {
                continue
            }
            downFlags.insert(flag)
            post(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: downFlags, timestamp: timestamp, windowNumber: windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)), windowNumber: windowNumber)
        }
        post(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: pressFlags, timestamp: timestamp, windowNumber: windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCodeValue), windowNumber: windowNumber)
        post(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: pressFlags, timestamp: timestamp, windowNumber: windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: charactersIgnoringModifiers, isARepeat: false, keyCode: keyCodeValue), windowNumber: windowNumber)
        var upFlags = pressFlags
        for (code, flag) in [(kVK_Command, NSEvent.ModifierFlags.command), (kVK_Option, .option), (kVK_Shift, .shift), (kVK_Control, .control)] {
            guard pressFlags.contains(flag) else {
                continue
            }
            upFlags.remove(flag)
            post(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: upFlags, timestamp: timestamp, windowNumber: windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)), windowNumber: windowNumber)
        }
        post(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: windowNumber, context: nil, subtype: sentinelSubtype, data1: 0, data2: 0), windowNumber: windowNumber)
    }

    // Posts an event to the application's queue, or stops the app when AppKit made none.
    private static func post(_ event: NSEvent?, windowNumber: Int) {
        guard let event = event else {
            ZiggyBridge.fail("AppKit made no event for the key press in window \(windowNumber)")
        }
        NSApp.postEvent(event, atStart: false)
    }

    // The key code of the keyboard key that types the name's character, and whether the layout needs Shift for it.
    private static func keyCodeAndShift(for keyName: String, key: String) -> (Int, Bool)? {
        if let named = namedKeyCodes[keyName] {
            return (named, false)
        }
        let character: String
        if keyName.count == 1 {
            character = keyName
        }
        else if keyName == "plus" {
            character = "+"
        }
        else if keyName == "minus" {
            character = "-"
        }
        else if keyName == "equal" {
            character = "="
        }
        else {
            return nil
        }
        let keyboardType = UInt32(LMGetKbdType())
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layout = Unmanaged<CFData>.fromOpaque(rawLayout).takeUnretainedValue() as Data
        for code in 0..<128 {
            if character(for: UInt16(code), layout: layout, flags: [], keyboardType: keyboardType) == character {
                return (code, false)
            }
        }
        for code in 0..<128 {
            if character(for: UInt16(code), layout: layout, flags: [.shift], keyboardType: keyboardType) == character {
                return (code, true)
            }
        }
        return nil
    }

    // The characters the key types with the flags held, from the layout, or nil when it types none.
    private static func character(for keyCode: UInt16, layout: Data, flags: NSEvent.ModifierFlags, keyboardType: UInt32) -> String? {
        var modifierState: UInt32 = 0
        if flags.contains(.shift) {
            modifierState |= UInt32(shiftKey)
        }
        if flags.contains(.option) {
            modifierState |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifierState |= UInt32(controlKey)
        }
        if flags.contains(.command) {
            modifierState |= UInt32(cmdKey)
        }
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else {
                return OSStatus(paramErr)
            }
            let keyboardLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            return UCKeyTranslate(keyboardLayout, keyCode, UInt16(kUCKeyActionDown), modifierState, keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        }
        if status != noErr || length == 0 {
            return nil
        }
        return String(utf16CodeUnits: characters, count: length)
    }
}
