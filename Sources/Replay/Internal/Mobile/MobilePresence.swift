#if canImport(UIKit)
import Foundation
#if canImport(SocketIO)
import SocketIO
#endif

/// Live-presence socket — a faithful port of the web SDK's `presence.ts`.
///
/// Opens a Socket.IO connection authenticated as `role="sdk"` with the same
/// project key + session id the HTTP transport uses. The backend
/// `LiveGateway` marks the session's EndUser online on connect and offline
/// ~10s after the socket drops (app background / terminate / network loss),
/// which is how the dashboard's "active users" list stays accurate for mobile.
///
/// socket.io-client-swift sends `connectParams` on the query string rather
/// than the Socket.IO v3 `auth` payload, so the gateway reads credentials
/// from either location. Entirely best-effort: any failure is swallowed so
/// presence can never affect capture.
///
/// SocketIO is an optional dependency: the SwiftPM build pulls it, but the
/// dependency-free CocoaPods spec (and any consumer without it) compiles the
/// socket calls out — presence simply no-ops, capture is unaffected. Guarded
/// the same way the crash reporter guards `CrashReporter`.
final class MobilePresence {
    #if canImport(SocketIO)
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var params: [String: Any] = [:]
    #endif

    func start(host: String, projectKey: String, sessionID: String, distinctID: String?) {
        #if canImport(SocketIO)
        guard let url = URL(string: host) else { return }
        stop()
        params = [
            "role": "sdk",
            "apiKey": projectKey,
            "sessionId": sessionID,
        ]
        if let d = distinctID, !d.isEmpty { params["distinctId"] = d }
        let manager = SocketManager(socketURL: url, config: [
            .path("/socket.io/"),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(8),
            .connectParams(params),
            .log(false),
            .compress,
        ])
        self.manager = manager
        let socket = manager.defaultSocket
        self.socket = socket
        socket.connect()
        #endif
    }

    /// identify() after the socket is up: refresh the credentials used on the
    /// next reconnect and nudge the server.
    func updateDistinctID(_ id: String) {
        #if canImport(SocketIO)
        guard !id.isEmpty else { return }
        params["distinctId"] = id
        manager?.setConfigs([.connectParams(params)])
        socket?.emit("sdk:identify", ["distinctId": id])
        #endif
    }

    func stop() {
        #if canImport(SocketIO)
        socket?.disconnect()
        socket = nil
        manager = nil
        #endif
    }
}
#endif
