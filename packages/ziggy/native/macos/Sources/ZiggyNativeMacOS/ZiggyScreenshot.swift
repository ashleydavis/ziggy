//
// Screenshots for the core's "screenshot" calls, which only the test control connection makes. The call reaches the app's main thread,
// which takes the snapshot with the web view's own takeSnapshot and returns at once: the snapshot's completion writes the file and
// gives the outcome.
//

import Foundation
import WebKit
import CZiggy
import AppKit

// Takes screenshots for the core's screenshot calls.
enum ZiggyScreenshot {
    // Writes a PNG of the web view to the path, on the main thread, and gives the completion nil once the file is written, or the
    // reason it could not be.
    static func take(webView: WKWebView, path: String, completion: @escaping (String?) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            completion(ZiggyScreenshot.save(image: image, error: error, path: path))
        }
    }

    // Writes the snapshot to the path as a PNG, and returns nil when it worked or the reason it did not.
    static func save(image: NSImage?, error: Error?, path: String) -> String? {
        if let error = error {
            return "the web view could not make a snapshot: \(error.localizedDescription)"
        }
        guard let image = image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return "the web view's snapshot has no pixels"
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return "the snapshot could not be encoded as a PNG"
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        }
        catch {
            return "could not write the screenshot to \(path): \(error.localizedDescription)"
        }
        return nil
    }
}
