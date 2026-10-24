//
// Ziggy's native app for iOS. It owns the WKWebView, injects window.ziggy, loads the app's bundled frontend, calls the
// core through the C interface and moves messages between the frontend and the core.
//
// Only the main thread touches the native app's state. The core posts its messages for the native app to the native app's queue and
// wakes the main thread through the main queue, and the main thread takes them (see native-message.zig in the core): it passes each
// message for the frontend to the web view and does each call. The app's native calls wait for the user, so they run one at a
// time on a queue of the native app's own, and their results go back to the core from the main thread.
//

import Foundation
import WebKit
import CZiggy
import UIKit

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

    // The pickers the core requested, which shutdown closes before it destroys the core.
    private let pickers = ZiggyPickers()

    // The queue the app's native calls run on, one at a time.
    private let requestQueue = DispatchQueue(label: "ziggy-native-calls")

    // The scheme and address of the bundled frontend. The files are embedded in the core library, not in the app bundle.
    private static let uiScheme = "ziggy-app"
    private static let appUrlPrefix = "ziggy-app://app/"

    // The app's private data directory, which the core is given.
    public let dataDirectory: URL

    // Whether a test hooks build was started in test mode.
    private let testMode: Bool

    // Handles the app's native calls. Set by setNativeCallHandler before start and read on the main thread only.
    private var nativeCallHandler: ZiggyNativeCallHandler?

    // Called on the main thread each time the core reports the app must be kept running (true) or no longer must be (false). The app sets
    // it before start.
    public var keepRunningChanged: ((Bool) -> Void)?

    // The requests the app itself made of the core, by the id each was sent under, with what to call when the core replies. Read and
    // written on the main thread only.
    private var appRequests: [String: (String?) -> Void] = [:]

    // The number the next request the app makes is numbered with. The ids it makes cannot collide with the frontend's, which are numbers.
    private var nextAppRequestNumber = 1

    // The background task that keeps an iOS app running for a while after it leaves the foreground, while the core's last keep-alive
    // call was true.
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // The name of the script message handler that the injected script posts through.
    private static let handlerName = "ziggy"

    // The name the os-version call gives the operating system.
    private static let operatingSystemName = "iOS"

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
        self.webView = WKWebView(frame: frame, configuration: configuration)

        super.init()

        configuration.userContentController.add(self, name: ZiggyBridge.handlerName)
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }


    // Gives the bridge the handler of the app's native calls. It must be called before start, because the core is told then
    // whether the app has one.
    public func setNativeCallHandler(_ handler: ZiggyNativeCallHandler) {
        if core != nil || destroyed {
            ZiggyBridge.fail("setNativeCallHandler was called after start")
        }
        nativeCallHandler = handler
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
        config.has_keep_alive = true
        config.has_pick_paths = true
        config.has_native_call = nativeCallHandler != nil
        config.worker_threads = 5
        config.max_concurrent_child_tasks = 2

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
        guard let created = ziggy_create(&config) else {
            ZiggyBridge.fail("ziggy_create failed")
        }
        core = created
        uiHandler.core = created


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

    // Destroys the core once. After it returns the core runs nothing and nothing more is delivered to the frontend.
    public func shutdown() {
        guard let handle = core else {
            return
        }
        // Any picker the core requested is closed first, with no result, because destroying the core gives every call not finished yet
        // its result.
        pickers.close()
        destroyed = true
        core = nil
        uiHandler.core = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ZiggyBridge.handlerName)
        ziggy_destroy(handle)
    }

    // Runs on the main thread: takes a background task while the core reports tasks the app must be kept running for are queued or
    // running, which lets the app run on after it leaves the foreground (the system ends it after a limited time, and the app is
    // suspended then), and gives it back when they end. A desktop app has no such callback: closing its window quits the app.
    private func setKeepsRunning(_ keep: Bool) {
        if keep && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ziggy-keep-alive") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        else if !keep {
            endBackgroundTask()
        }
        keepRunningChanged?(keep)
    }

    // Gives the background task back to the system.
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // Ends the app. Only the core's test control connection makes this call.
    private func quit() {
        // iOS has no way to quit an app, so the process ends once the core is destroyed.
        shutdown()
        exit(0)
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

    // Runs on the main thread: does one call of the core's, and gives the core its result when it has one, at once or, for a picker or
    // a native call, once it is done.
    private func doCall(_ text: String, reply: UInt64) {
        guard let call = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let type = call["type"] as? String else {
            ZiggyBridge.fail("the core sent a call the native app cannot read: \(text)")
        }
        switch type {
        case "quit":
            quit()
        case "keep-alive":
            guard let keepRunning = call["keepRunning"] as? Bool else {
                ZiggyBridge.fail("the core sent a keep-alive call with no keepRunning: \(text)")
            }
            setKeepsRunning(keepRunning)
        case "os-version":
            let version = ProcessInfo.processInfo.operatingSystemVersion
            finishCall(reply, ok: true, text: "\"\(ZiggyBridge.operatingSystemName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)\"")
        case "pick-paths":
            guard let kind = call["kind"] as? Int else {
                ZiggyBridge.fail("the core sent a picker call with no kind: \(text)")
            }
            pickers.show(webView: webView, kind: Int32(kind), title: call["title"] as? String, initialName: call["initialName"] as? String) { [weak self] outcome in
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
            }
        case "native-call":
            guard let method = call["method"] as? String, let request = call["request"] as? String else {
                ZiggyBridge.fail("the core sent a native call with no method or request: \(text)")
            }
            guard let handler = nativeCallHandler else {
                ZiggyBridge.fail("the core sent a native call but the bridge has no handler")
            }
            requestQueue.async { [weak self] in
                let result = ZiggyNativeCallResult.run(handler: handler, method: method, requestJson: request)
                DispatchQueue.main.async {
                    self?.finishCall(reply, ok: result.succeeded, text: result.text)
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
        // A reply to a request the app made itself is for the app, not the frontend.
        if consumeAppReply(text) {
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

    // Sends the core a one-way message for the app's message handler, as the frontend's send does, under the name the handler dispatches on. The data is anything JSON can hold. Can be called from any thread.
    public func send(name: String, data: Any) {
        DispatchQueue.main.async {
            let message: [String: Any] = [
                "kind": "app",
                "name": name,
                "data": data,
            ]
            self.post(ZiggyBridge.jsonText(message))
        }
    }

    // Makes a request of the core under a name, as the frontend's invoke does, for an app that has to start work itself (when the system wakes
    // it with the frontend not on screen, for instance). The core's reply comes to the completion on the main thread, with nil when the
    // request succeeded and the core's reason when it failed, and it is not given to the frontend. Can be called from any thread.
    public func request(name: String, data: Any, completion: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            let id = "app-\(self.nextAppRequestNumber)"
            self.nextAppRequestNumber += 1
            self.appRequests[id] = completion
            let message: [String: Any] = [
                "kind": "app",
                "id": id,
                "name": name,
                "data": data,
            ]
            self.post(ZiggyBridge.jsonText(message))
        }
    }

    // If the message is the reply to a request the app made, hands it to that request's completion and returns true.
    private func consumeAppReply(_ text: String) -> Bool {
        if appRequests.isEmpty {
            return false
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? String,
              let completion = appRequests.removeValue(forKey: id) else {
            return false
        }
        if let succeeded = object["ok"] as? Bool, succeeded {
            completion(nil)
        }
        else {
            completion(object["error"] as? String ?? "the core gave no reason")
        }
        return true
    }

    // Writes a message as JSON text.
    private static func jsonText(_ message: [String: Any]) -> String {
        do {
            return String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        }
        catch {
            ZiggyBridge.fail("could not write a message to the core: \(error)")
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
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                ZiggyBridge.report("could not open \(url.absoluteString) in the system browser")
            }
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
