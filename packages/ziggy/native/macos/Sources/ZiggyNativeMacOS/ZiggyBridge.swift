//
// Ziggy's native app for MacOS. It owns the WKWebView, injects window.ziggy, loads the app's bundled frontend, calls the
// core through the C interface and moves messages between the frontend and the core.
//
// Only the main thread touches the native app's state. The core posts its messages for the native app to the native app's queue and
// wakes the main thread through the main queue, and the main thread takes them (see native-message.zig in the core): it passes each
// message for the frontend to the web view and does each call, giving the core the result of each call that has one.
//

import Foundation
import WebKit
import CZiggy
import AppKit

// Serves the web view's requests for the bundled frontend from the files embedded in the core library, calling ziggy_ui_file
// for each file. The frontend's address is ziggy-app://app/, and the core is given to the handler once it exists.
// It runs on the main thread, as does everything that sets or clears the core.
final class ZiggyUiSchemeHandler: NSObject, WKURLSchemeHandler {
    // The core's handle, from start until shutdown. Null means the frontend cannot be served.
    var core: UnsafeMutableRawPointer?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            ZiggyBridge.fail("a request for the UI has no address")
        }
        guard let handle = core else {
            urlSchemeTask.didFailWithError(URLError(.cancelled))
            return
        }
        let path = url.path
        var result = ziggy_ui_file_result()
        let found = path.withCString { pointer in
            ziggy_ui_file(handle, pointer, path.utf8.count, &result)
        }
        if !found {
            guard let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil) else {
                ZiggyBridge.fail("could not make a 404 response for \(url)")
            }
            urlSchemeTask.didReceive(notFound)
            urlSchemeTask.didFinish()
            return
        }
        // The bytes live in the library for as long as it is loaded, so they are not copied.
        let content = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: result.content), count: Int(result.content_length), deallocator: .none)
        let headers = [
            "Content-Type": String(cString: result.content_type),
            "Content-Length": String(content.count),
        ]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            ZiggyBridge.fail("could not make a response for \(url)")
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(content)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    }
}

// A web view that tells its owner the files of a drop before WebKit handles the drop, so that when the frontend's drop event
// runs the files are already recorded with the core.
final class ZiggyWebView: WKWebView {
    // Called with the paths of the files dropped on the view.
    var onFilesDropped: (([String]) -> Void)?

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            onFilesDropped?(urls.map { $0.path })
        }
        return super.performDragOperation(sender)
    }
}

// Hosts one web view and one Ziggy core for the app. The app creates it, puts webView on screen, calls start, and calls
// shutdown when the app is ending.
public final class ZiggyBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    // The web view that shows the app's frontend. The app puts it on screen.
    public let webView: WKWebView

    // The core's handle, from start until shutdown.
    private var core: UnsafeMutableRawPointer?

    // Set by shutdown. Read and written on the main thread only, so nothing is delivered to the frontend after it is set.
    private var destroyed: Bool

    // Serves the web view's requests for the bundled frontend, from the core.
    private let uiHandler = ZiggyUiSchemeHandler()

    // The scheme and address of the bundled frontend. The files are embedded in the core library, not in the app bundle.
    private static let uiScheme = "ziggy-app"
    private static let appUrlPrefix = "ziggy-app://app/"

    // The app's private data directory, which the core is given.
    private let dataDirectory: URL

    // Whether a test hooks build was started in test mode.
    private let testMode: Bool

    // The main menu, once the core exists. This holds it because a menu item's target is not retained.
    private var menu: ZiggyMenu?

    // The pickers the core requested, which shutdown closes before it destroys the core.
    private let pickers = ZiggyPickers()

    // The name of the script message handler that the injected script posts through.
    private static let handlerName = "ziggy"

    // The name the os-version call gives the operating system.
    private static let operatingSystemName = "macOS"

    // Creates the web view with the injected script and the message handler. The frontend is not loaded and the core does not
    // exist until start. The frontend and the injected script are both embedded in the core library, so the app supplies
    // neither.
    public init(frame: CGRect) {
        let bundle = Bundle.main
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            ZiggyBridge.fail("the app has no bundle identifier")
        }
        var injectScriptLength = 0
        guard let injectScriptText = ziggy_inject_script(&injectScriptLength) else {
            ZiggyBridge.fail("the core has no inject script")
        }
        let injectScript = String(cString: injectScriptText)

        let supportDirectory: URL
        do {
            supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        catch {
            ZiggyBridge.fail("could not find the Application Support directory: \(error)")
        }
        let dataDirectory = supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }
        catch {
            ZiggyBridge.fail("could not create \(dataDirectory.path): \(error)")
        }
        self.dataDirectory = dataDirectory

        self.testMode = ziggy_test_hooks_enabled() && ProcessInfo.processInfo.environment["ZIGGY_TEST_MODE"] != nil
        self.core = nil
        self.destroyed = false

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(uiHandler, forURLScheme: ZiggyBridge.uiScheme)
        let userScript = WKUserScript(source: injectScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(userScript)
        // Turns on the web inspector, and with it Inspect Element in the context menu. This key is not in the public API but
        // is how every WKWebView app on these SDKs does it. It is on in release builds too.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        self.webView = ZiggyWebView(frame: frame, configuration: configuration)
        #if swift(>=5.8)
        // The public switch for the same thing, which exists from macOS 13.3. It is compiled only by a toolchain whose SDK
        // has it, because Xcode 14.2's SDK does not.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
        #endif

        super.init()

        configuration.userContentController.add(self, name: ZiggyBridge.handlerName)
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        (self.webView as! ZiggyWebView).onFilesDropped = { [weak self] paths in
            self?.filesDropped(paths)
        }
    }

    // Runs on the main thread: records the files of a drop with the core, so the frontend can get the path of each one it is given.
    private func filesDropped(_ paths: [String]) {
        guard let handle = core else {
            return
        }
        let json: Data
        do {
            json = try JSONSerialization.data(withJSONObject: paths)
        }
        catch {
            ZiggyBridge.fail("could not write the dropped files as JSON: \(error)")
        }
        let recorded = json.withUnsafeBytes { bytes -> Bool in
            ziggy_files_dropped(handle, bytes.bindMemory(to: CChar.self).baseAddress, json.count)
        }
        if !recorded {
            ZiggyBridge.report("the core could not record the dropped files")
        }
    }

    // Creates the core and loads the app's frontend.
    public func start() {
        if core != nil || destroyed {
            ZiggyBridge.fail("start was called more than once")
        }
        let environment = ProcessInfo.processInfo.environment

        var config = ziggy_config()
        // The main queue hands the bridge's address back to the main thread, which is the only thread that reads it.
        config.wake_data = Unmanaged.passUnretained(self).toOpaque()
        config.wake = { wakeData in
            DispatchQueue.main.async {
                guard let wakeData = wakeData else {
                    ZiggyBridge.fail("the core woke the native app with no bridge")
                }
                Unmanaged<ZiggyBridge>.fromOpaque(wakeData).takeUnretainedValue().takeCoreMessages()
            }
        }
        config.has_os_version = true
        config.has_quit = true
        config.has_pick_paths = true
        config.has_menu_action = true
        config.has_screenshot = true
        config.worker_threads = UInt32(ProcessInfo.processInfo.activeProcessorCount)
        config.max_concurrent_child_tasks = 10

        let prefixText = ZiggyBridge.duplicate(ZiggyBridge.appUrlPrefix)
        let dataText = ZiggyBridge.duplicate(dataDirectory.path)
        var portFileText: UnsafeMutablePointer<CChar>? = nil
        defer {
            free(prefixText)
            free(dataText)
            free(portFileText)
        }
        config.app_url_prefix = UnsafePointer(prefixText)
        config.data_dir = UnsafePointer(dataText)
        if testMode {
            config.test_mode = true
            if let portFile = environment["ZIGGY_TEST_PORT_FILE"] {
                portFileText = ZiggyBridge.duplicate(portFile)
                config.test_port_file = UnsafePointer(portFileText)
            }
        }
        // The command-line arguments after the program's name, for the app to read its own options from. They live as long as the
        // process.
        config.arg_count = UInt32(CommandLine.argc - 1)
        config.args = UnsafeRawPointer(CommandLine.unsafeArgv + 1).assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        guard let created = ziggy_create(&config) else {
            ZiggyBridge.fail("ziggy_create failed")
        }
        core = created
        uiHandler.core = created

        var menuLength = 0
        guard let menuText = ziggy_menu_json(created, &menuLength) else {
            ZiggyBridge.fail("the core has no menu text")
        }
        menu = ZiggyMenu(bridge: self, menuJSON: Data(bytes: menuText, count: menuLength))

        // The app supplies the query, which is passed through unread.
        var queryLength = 0
        guard let queryText = ziggy_ui_query(created, &queryLength) else {
            ZiggyBridge.fail("the app could not make the UI's query")
        }
        let query = String(decoding: UnsafeRawBufferPointer(start: queryText, count: queryLength), as: UTF8.self)
        var components = URLComponents(string: ZiggyBridge.appUrlPrefix + "index.html")
        if !query.isEmpty {
            components?.percentEncodedQuery = query
        }
        guard let uiURL = components?.url else {
            ZiggyBridge.fail("could not build the UI address")
        }
        webView.load(URLRequest(url: uiURL))
    }

    // Destroys the core once. After it returns the core runs nothing and nothing more is delivered to the frontend. The picker showing
    // is closed first and its pick ends as cancelled, while the core can still take the result; destroying the core gives every other
    // call not finished yet its result.
    public func shutdown() {
        guard let handle = core else {
            return
        }
        pickers.close()
        destroyed = true
        core = nil
        uiHandler.core = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ZiggyBridge.handlerName)
        ziggy_destroy(handle)
    }


    // Ends the app. Only the core's test control connection requests this.
    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // Runs on the main thread: takes every message the core has posted for the native app, passing each message for the frontend to
    // the web view and doing each call.
    private func takeCoreMessages() {
        while let handle = core {
            var length = 0
            var kind: Int32 = 0
            var reply: UInt64 = 0
            guard let text = ziggy_take_native_message(handle, &length, &kind, &reply) else {
                return
            }
            // The text is valid only until the next take, so it is copied.
            let message = String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
            if Int(kind) == Int(ZIGGY_NATIVE_DELIVER) {
                deliverToUi(message)
                continue
            }
            doCall(message, reply: reply)
        }
    }

    // Runs on the main thread: does one call of the core's, and gives the core its result when it has one, at once or, for a picker or a
    // screenshot, once it is done.
    private func doCall(_ text: String, reply: UInt64) {
        guard let call = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = call["type"] as? String else {
            ZiggyBridge.fail("the core sent a call the native app cannot read: \(text)")
        }
        switch type {
        case "quit":
            quit()
        case "menu-action":
            guard let action = call["action"] as? String else {
                ZiggyBridge.fail("the core sent a menu action with no action: \(text)")
            }
            guard let menu = menu else {
                ZiggyBridge.fail("the core chose the menu action \(action) before there was a menu")
            }
            menu.perform(action: action)
        case "os-version":
            let version = ProcessInfo.processInfo.operatingSystemVersion
            finishCall(reply, ok: true, text: "\"\(ZiggyBridge.operatingSystemName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)\"")
        case "pick-paths":
            guard let kind = call["kind"] as? Int else {
                ZiggyBridge.fail("the core sent a picker call with no kind: \(text)")
            }
            pickers.show(ZiggyPickRequest(kind: Int32(kind), title: call["title"] as? String, initialName: call["initialName"] as? String) { [weak self] outcome in
                switch outcome {
                case .failed(let reason):
                    self?.finishCall(reply, ok: false, text: reason)
                case .chosen(let paths):
                    guard let json = ZiggyPickers.json(paths: paths) else {
                        self?.finishCall(reply, ok: false, text: "the chosen paths could not be written as JSON")
                        return
                    }
                    self?.finishCall(reply, ok: true, text: json)
                }
            })
        case "screenshot":
            guard let path = call["outputPath"] as? String else {
                ZiggyBridge.fail("the core sent a screenshot call with no path: \(text)")
            }
            ZiggyScreenshot.take(webView: webView, path: path) { [weak self] failure in
                if let failure = failure {
                    self?.finishCall(reply, ok: false, text: failure)
                }
                else {
                    self?.finishCall(reply, ok: true, text: "")
                }
            }
        default:
            ZiggyBridge.fail("the core sent a call the native app does not do: \(text)")
        }
    }

    // Runs on the main thread: gives the core the result of its call taken under the number reply, unless the core has been destroyed,
    // which gave the call its result already.
    private func finishCall(_ reply: UInt64, ok: Bool, text: String) {
        guard let handle = core else {
            return
        }
        text.withCString { pointer in
            ziggy_native_result(handle, reply, ok, pointer, text.utf8.count)
        }
    }

    // Runs on the main thread: sends one message from the core to the frontend.
    private func deliverToUi(_ text: String) {
        // A message queued before shutdown is dropped here, because shutdown promises nothing is delivered after it.
        if destroyed {
            return
        }
        webView.evaluateJavaScript("window.__ziggyReceive(\(text));") { _, error in
            if let error = error {
                ZiggyBridge.report("delivering a message to the UI failed: \(error)")
            }
        }
    }

    // A message from the frontend: hands it to the core.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else {
            ZiggyBridge.fail("the UI posted a message that is not a string")
        }
        post(text)
    }

    // Gives the core a JSON message, as if the frontend had posted it.
    func post(_ text: String) {
        // The frontend can still post while the app is ending. The core is gone by then, so there is nobody to give it to.
        guard let handle = core else {
            return
        }
        text.withCString { pointer in
            ziggy_send_message(handle, pointer, text.utf8.count)
        }
    }

    // Tells the core that an app-owned menu item was chosen, as the menu-action message. The core runs the app's item.
    func postMenuAction(_ action: String) {
        let message: [String: Any] = [
            "kind": "system",
            "name": "menu-action",
            "data": [
                "action": action,
            ],
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        }
        catch {
            ZiggyBridge.fail("could not write the menu-action message: \(error)")
        }
        post(String(decoding: data, as: UTF8.self))
    }

    // Decides every navigation with the core's origin check.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if shouldLoad(navigationAction.request.url, isNewWindow: false) {
            decisionHandler(.allow)
        }
        else {
            decisionHandler(.cancel)
        }
    }

    // Decides window.open and target="_blank" with the same check. No new window is ever created.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        _ = shouldLoad(navigationAction.request.url, isNewWindow: true)
        return nil
    }

    // Reports a frontend that failed to load.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ZiggyBridge.report("the UI failed to load: \(error)")
    }

    // Reports a frontend that failed part way through loading.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ZiggyBridge.report("the UI failed while loading: \(error)")
    }

    // The web content process dying leaves a blank page that nothing can recover, so the app stops.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ZiggyBridge.fail("the web content process terminated")
    }

    // Has the core decide what to do with an address. An external link is opened in the system browser here. Returns true when
    // the web view may load the address, which is only for the app's own frontend in an existing frame.
    private func shouldLoad(_ url: URL?, isNewWindow: Bool) -> Bool {
        guard let handle = core else {
            return false
        }
        guard let url = url else {
            ZiggyBridge.report("blocked a navigation with no address")
            return false
        }
        let text = url.absoluteString
        let verdict = text.withCString { pointer in
            ziggy_check_url(handle, pointer, text.utf8.count)
        }
        if Int(verdict) == Int(ZIGGY_URL_ALLOW) {
            return !isNewWindow
        }
        if Int(verdict) == Int(ZIGGY_URL_OPEN_EXTERNALLY) {
            openExternally(url)
            return false
        }
        ZiggyBridge.report("blocked a navigation to \(text)")
        return false
    }

    // Opens an address in the system browser.
    private func openExternally(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            ZiggyBridge.report("could not open \(url.absoluteString) in the system browser")
        }
    }

    // Copies text into a new NUL terminated C string, which the caller frees.
    private static func duplicate(_ text: String) -> UnsafeMutablePointer<CChar> {
        guard let copy = strdup(text) else {
            ZiggyBridge.fail("out of memory")
        }
        return copy
    }

    // Writes a problem to standard error and carries on.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data("ziggy native app: \(message)\n".utf8))
    }

    // Writes a problem to standard error and stops the app.
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ziggy native app: \(message)\n".utf8))
        exit(1)
    }
}
