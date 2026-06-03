#if canImport(UIKit)
import Foundation
import SocketIO

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
final class MobilePresence {
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var params: [String: Any] = [:]

    func start(host: String, projectKey: String, sessionID: String, distinctID: String?) {
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
    }

    /// identify() after the socket is up: refresh the credentials used on the
    /// next reconnect and nudge the server.
    func updateDistinctID(_ id: String) {
        guard !id.isEmpty else { return }
        params["distinctId"] = id
        manager?.setConfigs([.connectParams(params)])
        socket?.emit("sdk:identify", ["distinctId": id])
    }

    func stop() {
        socket?.disconnect()
        socket = nil
        manager = nil
    }
}
#endif
