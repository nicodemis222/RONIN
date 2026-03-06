import Foundation
import os.log

private let logger = Logger(subsystem: "com.ronin.app", category: "WebSocket")

class WebSocketService {
    private var webSocketTask: URLSessionWebSocketTask?
    private let url: URL
    private let session = URLSession(configuration: .default)
    private(set) var isConnected = false
    private var shouldReconnect = true
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var sendFailureCount = 0

    var onMessage: ((ParsedWSMessage) -> Void)?
    var onDisconnect: (() -> Void)?
    var onConnected: (() -> Void)?
    var onError: ((String) -> Void)?

    init(url: URL, authToken: String = "") {
        // Append auth token as query parameter for WebSocket authentication
        if !authToken.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = [URLQueryItem(name: "token", value: authToken)]
            self.url = components.url ?? url
        } else {
            self.url = url
        }
        logger.info("WebSocketService init")
    }

    deinit {
        // Safety net: cancel any live task when this service is deallocated
        // so we never leave an orphaned connection on the backend
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    func connect() {
        shouldReconnect = true
        reconnectAttempts = 0
        logger.info("connect() called")
        attemptConnect()
    }

    private func attemptConnect() {
        guard shouldReconnect else {
            logger.info("attemptConnect skipped — shouldReconnect=false")
            return
        }

        logger.info("attemptConnect — attempt #\(self.reconnectAttempts)")

        // Cancel any existing task before creating a new one
        webSocketTask?.cancel(with: .goingAway, reason: nil)

        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        // Ping to verify connection is alive
        webSocketTask?.sendPing { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                logger.error("Ping failed: \(error.localizedDescription)")
                self.isConnected = false
                self.onError?("Failed to connect: \(error.localizedDescription)")
                self.scheduleReconnect()
            } else {
                logger.info("Ping succeeded — connected!")
                self.isConnected = true
                self.reconnectAttempts = 0
                self.sendFailureCount = 0
                self.onConnected?()
                self.receiveMessage()
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error {
                self?.sendFailureCount += 1
                if self?.sendFailureCount ?? 0 <= 3 {
                    logger.error("Send failed (#\(self?.sendFailureCount ?? 0)): \(error.localizedDescription)")
                }
                self?.isConnected = false
                self?.onError?("Send failed: \(error.localizedDescription)")
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.shouldReconnect else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        if let parsed = ParsedWSMessage.parse(from: data) {
                            self.onMessage?(parsed)
                        } else {
                            logger.warning("Failed to parse WS message: \(text.prefix(200))")
                        }
                    }
                case .data(let data):
                    if let parsed = ParsedWSMessage.parse(from: data) {
                        self.onMessage?(parsed)
                    } else {
                        logger.warning("Failed to parse WS binary message (\(data.count) bytes)")
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()

            case .failure(let error):
                logger.error("Receive failed: \(error.localizedDescription)")
                self.isConnected = false
                self.onError?("Connection lost: \(error.localizedDescription)")
                self.onDisconnect?()
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectAttempts < maxReconnectAttempts else {
            if reconnectAttempts >= maxReconnectAttempts {
                logger.error("Max reconnect attempts (\(self.maxReconnectAttempts)) reached")
                onError?("Failed to reconnect after \(maxReconnectAttempts) attempts. Check that the backend is running.")
            }
            return
        }

        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 2.0, 10.0)
        logger.info("Scheduling reconnect #\(self.reconnectAttempts) in \(delay)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect, !self.isConnected else { return }
            self.attemptConnect()
        }
    }

    func disconnect() {
        logger.info("disconnect() called")
        shouldReconnect = false
        isConnected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }
}
