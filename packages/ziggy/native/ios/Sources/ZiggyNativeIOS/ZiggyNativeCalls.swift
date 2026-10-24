//
// How an app's own iOS code handles the core's native calls: the things only the platform can do (a permission prompt, the
// keychain, a share sheet), each named by a method. The core knows no method names, they are the app's and its handler's. The app
// gives its handler to ZiggyBridge.setNativeCallHandler before ZiggyBridge.start.
//

import Foundation

// What a ZiggyNativeCallHandler throws when it cannot do what a native call's method names. The reason is in words the user can act on, and it
// is passed to the core as the failure text of the call.
public struct ZiggyNativeCallError: Error {
    // Why the call could not be done.
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

// Handles the core's native calls for the app.
public protocol ZiggyNativeCallHandler: AnyObject {
    // Does what the method names with the JSON text of its argument and returns the JSON text of the result. It is called on the
    // native app's own queue for native calls, never the main thread, one call at a time, and may block for as long as it takes,
    // for instance until a permission dialog closes. It throws ZiggyNativeCallError, with the reason in words the user can act on, for
    // a method it does not know or cannot do.
    func handle(method: String, requestJson: String) throws -> String
}

// What a native call came to: whether it succeeded, and the JSON text of its result or the reason it failed.
struct ZiggyNativeCallResult {
    let succeeded: Bool
    let text: String

    // Runs the handler for one call and gives its result, or the reason it failed.
    static func run(handler: ZiggyNativeCallHandler, method: String, requestJson: String) -> ZiggyNativeCallResult {
        do {
            return ZiggyNativeCallResult(succeeded: true, text: try handler.handle(method: method, requestJson: requestJson))
        }
        catch let failure as ZiggyNativeCallError {
            return ZiggyNativeCallResult(succeeded: false, text: failure.reason)
        }
        catch {
            return ZiggyNativeCallResult(succeeded: false, text: "The native call \(method) failed: \(error)")
        }
    }
}
