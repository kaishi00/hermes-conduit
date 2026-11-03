//
//  ServerCertificateProfile.swift
//  Conduit
//
//  The HTTPS & certificates page's "Install this certificate" step. A
//  dashboard with its own certificate authority (or a self-signed
//  certificate) connects once iOS trusts that root, and the hard part for
//  people is getting the root onto the device. This reads the certificate
//  the server presents and saves its root as a configuration profile, which
//  the user installs and trusts in Settings.
//
//  It never accepts a certificate iOS refuses (Eric, 2026-10-19, issue
//  #129): the check's own connection cancels every trust challenge, so it
//  only reads the chain, and what Conduit connects to is still decided by
//  iOS alone, through the profile the user chose to install.
//

import CryptoKit
import Foundation
import Security

/// One certificate the server presented.
struct ServerCertificate: Equatable {
    let der: Data
    /// The certificate's name, as Settings shows it.
    let subject: String
    /// Issued by itself: a root, or a self-signed server certificate.
    let isSelfSigned: Bool

    init(der: Data, subject: String, isSelfSigned: Bool) {
        self.der = der
        self.subject = subject
        self.isSelfSigned = isSelfSigned
    }

    init(_ certificate: SecCertificate) {
        let der = SecCertificateCopyData(certificate) as Data
        let subject = SecCertificateCopySubjectSummary(certificate) as String?
        let subjectSequence = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?
        let issuerSequence = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
        self.init(
            der: der,
            subject: subject ?? "",
            isSelfSigned: subjectSequence != nil && subjectSequence == issuerSequence
        )
    }

    /// SHA-256 of the certificate, as servers and `openssl x509 -fingerprint
    /// -sha256` print it: uppercase hex pairs joined by colons.
    var sha256Fingerprint: String {
        SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// What the check found, and so what the page offers.
enum ServerCertificateCheck: Equatable {
    /// iOS already trusts the server: certificates aren't the problem.
    case alreadyTrusted
    /// Only the root is untrusted, and the server sent it: installing and
    /// trusting it is the fix.
    case installable(ServerCertificate)
    /// Only the root is untrusted, but the server doesn't send it, so
    /// Conduit can't save it. The root comes from wherever the certificates
    /// were made.
    case rootNotSent
    /// Trusting a root wouldn't be enough: the certificate has the wrong
    /// name, breaks Apple's rules or is out of date.
    case notFixedByInstalling(ConnectionFailure)
    /// The server couldn't be reached to read its certificate.
    case unreachable(ConnectionFailure)

    /// Decides from a server trust iOS has evaluated (or evaluates here).
    /// Only the trust's own verdict and its failed checks are read, as the
    /// connection failure messages do (TLSTrustDiagnosis).
    static func from(_ trust: SecTrust) -> ServerCertificateCheck {
        if SecTrustEvaluateWithError(trust, nil) { return .alreadyTrusted }
        let failure = TLSTrustDiagnosis.failure(for: trust) ?? .tlsUntrusted
        guard failure == .tlsUntrusted else { return .notFixedByInstalling(failure) }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard let top = chain.last else { return .rootNotSent }
        let certificate = ServerCertificate(top)
        return certificate.isSelfSigned ? .installable(certificate) : .rootNotSent
    }
}

/// Reads the certificate an https address presents, without accepting it.
enum ServerCertificateInspector {
    static func check(_ url: URL) async -> ServerCertificateCheck {
        let reader = TrustReader()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        do {
            _ = try await session.data(for: request)
        } catch {
            if let found = reader.found { return found }
            return .unreachable(ConnectionFailureClassifier.classify(error))
        }
        // Reached without a trust challenge: nothing for the check to read,
        // and the system accepted the connection.
        return reader.found ?? .alreadyTrusted
    }

    /// Reads each server trust challenge and cancels it, so this connection
    /// never goes further than the handshake.
    private final class TrustReader: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var result: ServerCertificateCheck?

        var found: ServerCertificateCheck? {
            lock.lock(); defer { lock.unlock() }
            return result
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                let check = ServerCertificateCheck.from(trust)
                lock.lock()
                result = check
                lock.unlock()
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A configuration profile that installs one root certificate.
enum ServerCertificateProfile {
    /// The same certificate always gets the same identifier, so installing
    /// it again replaces the old profile instead of adding a second one.
    static func identifier(for certificate: ServerCertificate) -> String {
        let hex = SHA256.hash(data: certificate.der).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "com.milim.relay.certificate.\(hex)"
    }

    static func data(for certificate: ServerCertificate, host: String) throws -> Data {
        let identifier = identifier(for: certificate)
        let name = certificate.subject.isEmpty ? host : certificate.subject
        let root: [String: Any] = [
            "PayloadType": "com.apple.security.root",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier + ".root",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": name,
            "PayloadCertificateFileName": fileStem(host) + ".cer",
            "PayloadContent": certificate.der
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": name,
            "PayloadDescription": AppLocalization.string("Lets this device trust the certificate of your Hermes dashboard at \(host)."),
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [root]
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    /// Writes the profile where the share sheet can hand it over.
    static func write(_ certificate: ServerCertificate, host: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CertificateProfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileStem(host) + ".mobileconfig")
        try data(for: certificate, host: host).write(to: url, options: .atomic)
        return url
    }

    /// A file name from the host: letters, digits, dots and dashes, at most
    /// 100 characters (a host name can be 253, past a file name's limit).
    static func fileStem(_ host: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        let stem = String(host.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.prefix(100))
        return stem.isEmpty ? "dashboard" : stem
    }
}
