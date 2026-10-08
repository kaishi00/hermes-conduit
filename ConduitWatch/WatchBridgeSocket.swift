//
//  WatchBridgeSocket.swift
//  Conduit Watch
//
//  The Watch's WebSocket to the Hermes host's audio bridge through the
//  push relay (designs/apple-watch-gpt-live.md): binary messages only,
//  the grant's relay key as the bearer. URLSession, set up as the direct
//  call's working socket (WatchURLSessionGeminiLiveSocket): ephemeral,
//  audio streaming service type. No redirects: the key stays with the
//  relay.
//

import Foundation

@MainActor
final class WatchBridgeSocket {
    /// A binary message from the relay.
    var onMessage: ((Data) -> Void)?
    /// open, waiting, close (code, reason), complete (error), receiveFailed.
    var onEvent: ((String, [String: Any]) -> Void)?

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate = WatchBridgeSocketDelegate()
    private(set) var bytesUp = 0
    private(set) var bytesDown = 0
    private(set) var messagesDown = 0
    private var isClosed = false

    init(url: URL, watchKey: String) {
        var request = URLRequest(url: url)
        request.networkServiceType = .avStreaming
        request.setValue("Bearer \(watchKey)", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        // Above the relay's 64 KB bound on purpose: an oversized message is
        // dropped when it doesn't open, instead of failing the socket.
        task.maximumMessageSize = 1 << 20
        delegate.onEvent = { [weak self] kind, fields in
            WatchVoiceMain.async { self?.onEvent?(kind, fields) }
        }
        task.resume()
        receiveNext()
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The relay's close code once it closed, else nil.
    var closeCode: Int? {
        task.closeCode == .invalid ? nil : task.closeCode.rawValue
    }

    func send(_ data: Data, done: ((Bool) -> Void)? = nil) {
        guard !isClosed else {
            done?(false)
            return
        }
        bytesUp += data.count
        task.send(.data(data)) { error in
            WatchVoiceMain.async { done?(error == nil) }
        }
    }

    /// The relay closes a socket silent for a minute; audio may pause
    /// longer (muted, a long reply).
    func ping(done: @escaping (Bool) -> Void) {
        guard !isClosed else { return }
        task.sendPing { error in
            WatchVoiceMain.async { done(error == nil) }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            WatchVoiceMain.async {
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(.data(let data)):
                    self.bytesDown += data.count
                    self.messagesDown += 1
                    self.onMessage?(data)
                    self.receiveNext()
                case .success:
                    // The relay sends no text.
                    self.receiveNext()
                case .failure(let error):
                    let error = error as NSError
                    self.onEvent?("receiveFailed", ["domain": error.domain, "code": error.code, "closeCode": self.closeCode as Any])
                }
            }
        }
    }
}

private final class WatchBridgeSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onEvent: ((String, [String: Any]) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol negotiated: String?) {
        onEvent?("open", [:])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onEvent?("close", ["code": closeCode.rawValue, "reason": String(text.prefix(120))])
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        onEvent?("waiting", [:])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        var fields: [String: Any] = [:]
        if let error = error as NSError? {
            fields["domain"] = error.domain
            fields["code"] = error.code
            if let path = error.userInfo["_NSURLErrorNWPathKey"] {
                fields["path"] = String("\(path)".prefix(240))
            }
        }
        if let http = task.response as? HTTPURLResponse { fields["http"] = http.statusCode }
        onEvent?("complete", fields)
    }
}
