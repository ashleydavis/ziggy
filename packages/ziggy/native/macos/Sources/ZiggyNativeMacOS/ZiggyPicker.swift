//
// Native file and folder pickers, for the core's "pick-paths" calls. The calls reach the app's main thread, which shows the panel and
// returns at once: the panel's completion gives the outcome, one picker at a time. On MacOS these are NSOpenPanel and NSSavePanel.
// Everything here runs on the main thread. Before the core is destroyed the bridge closes the pickers: the one showing is cancelled
// and given the outcome of a cancelled picker, and the ones queued are dropped, because destroying the core gives their calls their
// results.
//

import Foundation
import WebKit
import CZiggy
import AppKit

// What the user did with a picker.
enum ZiggyPickOutcome {
    // The paths they chose, empty when they cancelled.
    case chosen([String])
    // The picker could not be shown or could not give a path, with the reason.
    case failed(String)
}

// One picker requested and not shown yet.
struct ZiggyPickRequest {
    // What to show.
    let kind: Int32
    let title: String?
    let initialName: String?
    // Called with the outcome.
    let completion: (ZiggyPickOutcome) -> Void
}

// The pickers the core requested, shown one after another on the main thread.
final class ZiggyPickers {
    // The pickers queued until the one showing closes, oldest first.
    private var queued: [ZiggyPickRequest] = []
    // The panel showing, or nil.
    private var showing: NSSavePanel?
    // The request of the panel showing, or nil.
    private var showingRequest: ZiggyPickRequest?
    // Set once closed: nothing more is shown and no outcome is given.
    private var closed = false

    // Shows a picker, or keeps it until the one showing closes, and gives its outcome to the completion.
    func show(_ request: ZiggyPickRequest) {
        if closed {
            return
        }
        queued.append(request)
        showNext()
    }

    // Cancels the picker showing, giving it the outcome of a cancelled picker as the Linux and Windows native apps do, so the pick
    // ends before the core is destroyed, and drops the ones queued, whose calls destroying the core fails. Giving the showing picker
    // no outcome left it to destroying the core: the MacOS smoke job's 25-close-with-dialog-open failed with "the app was still running
    // 30 seconds after it was told to quit with a file dialog open".
    func close() {
        closed = true
        queued = []
        if let panel = showing {
            let request = showingRequest
            showing = nil
            showingRequest = nil
            panel.cancel(nil)
            request?.completion(.chosen([]))
        }
    }

    // Shows the oldest picker queued, when none is showing.
    private func showNext() {
        if showing != nil || queued.isEmpty {
            return
        }
        let request = queued.removeFirst()
        guard let panel = ZiggyPickers.panel(kind: request.kind, title: request.title, initialName: request.initialName) else {
            request.completion(.failed("unknown picker kind \(request.kind)"))
            showNext()
            return
        }
        showing = panel
        showingRequest = request
        panel.begin { [weak self] response in
            guard let self = self, self.showing === panel else {
                return
            }
            self.showing = nil
            self.showingRequest = nil
            request.completion(ZiggyPickers.outcome(panel: panel, response: response))
            self.showNext()
        }
    }

    // The panel for the kind, or nil for a kind ziggy.h does not give.
    private static func panel(kind: Int32, title: String?, initialName: String?) -> NSSavePanel? {
        let panel: NSSavePanel
        switch Int(kind) {
        case Int(ZIGGY_PICK_OPEN_FILES):
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = true
            panel = openPanel
        case Int(ZIGGY_PICK_FOLDER):
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.canCreateDirectories = true
            panel = openPanel
        case Int(ZIGGY_PICK_SAVE_FILE):
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = initialName ?? ""
            panel = savePanel
        default:
            return nil
        }
        if let title = title {
            panel.title = title
            panel.message = title
        }
        return panel
    }

    // What the user did with a panel that closed.
    private static func outcome(panel: NSSavePanel, response: NSApplication.ModalResponse) -> ZiggyPickOutcome {
        if response != .OK {
            return .chosen([])
        }
        if let openPanel = panel as? NSOpenPanel {
            return .chosen(openPanel.urls.map { $0.path })
        }
        guard let url = panel.url else {
            return .failed("the save panel was accepted with no file")
        }
        return .chosen([url.path])
    }

    // The JSON array of the chosen paths, or nil after reporting why it could not be written.
    static func json(paths: [String]) -> String? {
        do {
            return String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
        }
        catch {
            ZiggyBridge.report("could not write the chosen paths as JSON: \(error)")
            return nil
        }
    }
}
