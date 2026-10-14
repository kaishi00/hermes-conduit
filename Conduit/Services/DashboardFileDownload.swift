//
//  DashboardFileDownload.swift
//  Conduit
//
//  Gateway files too large for a data URL (#569). `/api/fs/read-data-url`
//  stops at 16 MB on both ends, so a generated video or a long recording
//  could never open on the phone. Those files stream from `/api/fs/download`
//  straight to a file on disk instead, signed in the way the dashboard's
//  JSON requests are: the native sign-in token, or the dashboard's cookies.
//

import Foundation

/// A gateway file downloaded into a directory of its own. Whoever receives
/// it owns `directory` and removes it when done.
struct DashboardDownloadedFile: Sendable {
    let directory: URL
    let file: URL
    let mimeType: String?
}

enum DashboardFileDownloadLimits {
    /// The largest gateway file the phone downloads. It streams to disk, so
    /// this bounds storage and waiting, not memory.
    static let maxBytes = 512 * 1024 * 1024
}

extension DashboardTicketBridge {
    /// Downloads the dashboard file at `path` (a dashboard API path with its
    /// query) into a new directory under `root`, named after `filename`.
    /// Same error contract as `requestJSON`; a file over `maxBytes` is
    /// `.oversizedResponse`.
    func downloadFile(
        path: String,
        filename: String,
        into root: URL,
        maxBytes: Int = DashboardFileDownloadLimits.maxBytes
    ) async throws -> DashboardDownloadedFile {
        let request = try await fileDownloadRequest(path: path)
        return try await Self.download(request, filename: filename, into: root, maxBytes: maxBytes)
    }

    private func fileDownloadRequest(path: String) async throws -> URLRequest {
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        if let nativeOAuthSession {
            return try await nativeOAuthSession.authorizedRequest(path: path)
        }
        guard let url = Self.pageRequestURL(path: path, baseURL: baseURL) else {
            throw DashboardTicketBridgeError.requestFailed(AppLocalization.string("Could not encode dashboard request."))
        }
        // The page's own fetch would buffer the whole body inside WebKit and
        // hand it over as one string, so the file comes through URLSession
        // with the page's cookies, as requests sent without the page do.
        let cookies = await cookiesForRequestsWithoutPage()
        guard !isInvalidated else { throw DashboardTicketBridgeError.notReady }
        let cookieHeader = NativeAuthCookiePolicy.headerFields(for: cookies, url: url)
        guard !cookieHeader.isEmpty else { throw DashboardTicketBridgeError.notReady }
        var request = URLRequest(url: url).applyingProxyHeaders(cloudflare: cloudflareAccess)
        for (name, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Streams `request`'s body to `<root>/<uuid>/<filename>`, abandoning it
    /// (and removing the directory) once it passes `maxBytes`. Runs off the
    /// main actor.
    nonisolated static func download(
        _ request: URLRequest,
        filename: String,
        into root: URL,
        maxBytes: Int,
        session: URLSession = DashboardBackgroundSession.shared
    ) async throws -> DashboardDownloadedFile {
        var request = request
        request.httpMethod = "GET"
        // Limits the wait between bytes; a large file may take a while in
        // total.
        request.timeoutInterval = 30
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let result: (URLSession.AsyncBytes, URLResponse)
        do {
            result = try await session.bytes(for: request)
        } catch {
            throw mappedTransportError(error)
        }
        let (bytes, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw DashboardTicketBridgeError.http(status: 0, detail: "No response from the dashboard.")
        }
        if (300...399).contains(http.statusCode),
           (http.value(forHTTPHeaderField: "Location") ?? "").contains("/login") {
            throw DashboardTicketBridgeError.signInRequired
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw DashboardTicketBridgeError.signInRequired
        }
        guard (200...299).contains(http.statusCode) else {
            throw DashboardTicketBridgeError.http(
                status: http.statusCode,
                detail: AppLocalization.string("Dashboard request failed (\(String(http.statusCode))).")
            )
        }
        if http.expectedContentLength > Int64(maxBytes) {
            throw DashboardTicketBridgeError.oversizedResponse(limit: maxBytes)
        }

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent(MediaPreviewPresenter.sanitizedFilename(filename))
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            // Gather into a fixed chunk and write in bulk, as
            // `MediaPreviewPresenter.boundedDownload` does.
            let chunkSize = 256 * 1024
            var chunk = [UInt8]()
            chunk.reserveCapacity(chunkSize)
            var written = 0
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count == chunkSize {
                    written += chunk.count
                    guard written <= maxBytes else {
                        throw DashboardTicketBridgeError.oversizedResponse(limit: maxBytes)
                    }
                    try handle.write(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            written += chunk.count
            guard written <= maxBytes else {
                throw DashboardTicketBridgeError.oversizedResponse(limit: maxBytes)
            }
            try handle.write(contentsOf: chunk)
            guard written > 0 else {
                throw DashboardTicketBridgeError.http(status: http.statusCode, detail: "The dashboard sent an empty file.")
            }
            return DashboardDownloadedFile(directory: directory, file: file, mimeType: http.mimeType)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw mappedTransportError(error)
        }
    }

    /// A cancelled caller hears cancellation; a network failure is status 0,
    /// as the page's fetch reports it. Anything else passes through.
    private nonisolated static func mappedTransportError(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled { return CancellationError() }
        return DashboardTicketBridgeError.http(status: 0, detail: urlError.localizedDescription)
    }
}
