//
// Native file and folder pickers, for the core's "pick-paths" calls. The calls reach the app's main thread, which presents the picker
// and returns at once: the picker's delegate gives the outcome. The dialogs are UIDocumentPickerViewController, which can open files
// and choose a folder but has no dialog for choosing where to save. Everything here runs on the main thread. Before the core is
// destroyed the bridge closes the pickers: every one showing is dismissed without an outcome, because destroying the core gives
// their calls their results.
//

import Foundation
import WebKit
import CZiggy
import UIKit
import UniformTypeIdentifiers

// What the user did with a picker.
enum ZiggyPickOutcome {
    // The paths they chose, empty when they cancelled.
    case chosen([String])
    // The picker could not be shown or could not give a path, with the reason.
    case failed(String)
}

// The pickers the core requested that are showing.
final class ZiggyPickers {
    // The pickers showing.
    private var showing: [UIDocumentPickerViewController] = []
    // Set once closed: nothing more is presented and no outcome is given.
    private var closed = false

    // Presents a picker over the web view's window and gives its outcome to the completion.
    func show(webView: WKWebView, kind: Int32, title: String?, initialName: String?, completion: @escaping (ZiggyPickOutcome) -> Void) {
        if closed {
            return
        }
        var presented: UIDocumentPickerViewController?
        presented = ZiggyPickers.present(webView: webView, kind: kind, title: title, initialName: initialName) { [weak self] outcome in
            guard let self = self, !self.closed else {
                return
            }
            self.showing.removeAll { $0 === presented }
            completion(outcome)
        }
        if let picker = presented {
            showing.append(picker)
        }
    }

    // Dismisses every picker showing, giving none of them an outcome.
    func close() {
        closed = true
        for picker in showing {
            picker.dismiss(animated: false)
        }
        showing = []
    }

    // Presents a document picker over the web view's window and reports the outcome from its delegate, and returns the picker, or
    // nil when none was presented. Saving has no iOS dialog, so it fails.
    private static func present(webView: WKWebView, kind: Int32, title: String?, initialName: String?, completion: @escaping (ZiggyPickOutcome) -> Void) -> UIDocumentPickerViewController? {
        let picker: UIDocumentPickerViewController
        switch Int(kind) {
        case Int(ZIGGY_PICK_OPEN_FILES):
            // asCopy gives the app copies in its temporary directory, which it can read without any access to the originals.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
            picker.allowsMultipleSelection = true
        case Int(ZIGGY_PICK_FOLDER):
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        case Int(ZIGGY_PICK_SAVE_FILE):
            completion(.failed("iOS has no dialog for choosing where to save a file"))
            return nil
        default:
            completion(.failed("unknown picker kind \(kind)"))
            return nil
        }
        guard var presenter = webView.window?.rootViewController else {
            completion(.failed("the web view is not in a window with a root view controller"))
            return nil
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let title = title {
            picker.title = title
        }
        let delegate = ZiggyPickerDelegate(isFolder: Int(kind) == Int(ZIGGY_PICK_FOLDER), completion: completion)
        picker.delegate = delegate
        delegate.keepAlive = delegate
        presenter.present(picker, animated: true)
        return picker
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

// Receives a document picker's result. The picker holds its delegate weakly, so this keeps itself alive until it has the result.
final class ZiggyPickerDelegate: NSObject, UIDocumentPickerDelegate {
    // Whether the picker chose a folder, whose access must be started, rather than copies of files.
    private let isFolder: Bool

    // Reports the outcome.
    private let completion: (ZiggyPickOutcome) -> Void

    // Set to this object while the picker is showing, and cleared after it gives its result.
    var keepAlive: ZiggyPickerDelegate?

    // Creates the delegate for one picker.
    init(isFolder: Bool, completion: @escaping (ZiggyPickOutcome) -> Void) {
        self.isFolder = isFolder
        self.completion = completion
        super.init()
    }

    // The user chose something.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        keepAlive = nil
        if isFolder {
            guard let folder = urls.first else {
                completion(.failed("the folder picker returned no folder"))
                return
            }
            // Access to the folder lasts until the process ends, because nothing calls stopAccessingSecurityScopedResource.
            if !folder.startAccessingSecurityScopedResource() {
                completion(.failed("could not start accessing the folder \(folder.path)"))
                return
            }
        }
        completion(.chosen(urls.map { $0.path }))
    }

    // The user cancelled, which is a normal result of no paths.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        keepAlive = nil
        completion(.chosen([]))
    }
}
