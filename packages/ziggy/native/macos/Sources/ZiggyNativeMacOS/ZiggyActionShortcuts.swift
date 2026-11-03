//
// The shortcuts of the app's actions that have no menu item, on MacOS. A menu item's shortcut is its key equivalent, which AppKit
// handles, but these have no menu item to carry them, so one local key monitor matches every key press against them while the app is
// in front, and posts the menu-action message naming the action for one that matches.
//

import AppKit
import CZiggy

// A shortcut as AppKit uses it: the key equivalent's text and the modifier keys held with it.
struct ZiggyShortcutKey {
    // The key equivalent, as a menu item's keyEquivalent is written.
    let keyEquivalent: String

    // The modifier keys held with the key.
    let modifiers: NSEvent.ModifierFlags
}

// Registers the shortcuts of the app's actions that have no menu item, and posts the action of the one a key press matches.
final class ZiggyActionShortcuts {
    // The bridge the actions are posted through. Weak, because the bridge owns this object.
    private weak var bridge: ZiggyBridge?

    // Each action's name with its shortcut.
    private let shortcuts: [(action: String, key: ZiggyShortcutKey)]

    // The key monitor, removed when this object goes.
    private var monitor: Any?

    // The modifier keys a shortcut can hold, which a key press is compared on, leaving out such keys as Caps Lock.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    // Reads the shortcuts the core gave and installs the key monitor. The core's strings are read here, because they are valid only
    // until the core is destroyed.
    init(bridge: ZiggyBridge, shortcuts: UnsafeBufferPointer<ziggy_standalone_action_shortcut>) {
        self.bridge = bridge
        self.shortcuts = shortcuts.map { shortcut in
            let action = String(cString: shortcut.action)
            return (action: action, key: ZiggyMenu.parseShortcut(String(cString: shortcut.shortcut), owner: "The action \(action)"))
        }
        if self.shortcuts.isEmpty {
            return
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let action = self.matchingAction(event) else {
                return event
            }
            self.bridge?.postMenuAction(action)
            return nil
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // The action whose shortcut the key press is, or nil when it is none of them.
    private func matchingAction(_ event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection(ZiggyActionShortcuts.shortcutModifiers)
        for shortcut in shortcuts {
            if shortcut.key.keyEquivalent.lowercased() == characters && shortcut.key.modifiers == modifiers {
                return shortcut.action
            }
        }
        return nil
    }
}
