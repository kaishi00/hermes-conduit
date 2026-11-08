import Foundation
import Security
import XCTest
@testable import Conduit

/// The HTTPS page's "Install this certificate" step: what a server trust
/// offers, and the profile it saves. It never accepts a certificate iOS
/// refuses (issue #129).
final class ServerCertificateProfileTests: XCTestCase {
    func testSelfSignedCertificateWithTheRightNameIsInstallable() throws {
        let check = ServerCertificateCheck.from(try Self.trust(hostname: "hermes.home.arpa"))
        guard case .installable(let certificate) = check else {
            return XCTFail("expected installable, got \(check)")
        }
        XCTAssertTrue(certificate.isSelfSigned)
        XCTAssertEqual(certificate.subject, "hermes.home.arpa")
        XCTAssertEqual(certificate.der, try XCTUnwrap(Data(base64Encoded: Self.certificate)))
        let fingerprint = certificate.sha256Fingerprint
        XCTAssertEqual(fingerprint.count, 32 * 3 - 1)
        XCTAssertNotNil(fingerprint.range(of: #"^([0-9A-F]{2}:){31}[0-9A-F]{2}$"#, options: .regularExpression))
    }

    func testProblemsTrustingTheRootWouldNotFixAreNamedInstead() throws {
        XCTAssertEqual(
            ServerCertificateCheck.from(try Self.trust(hostname: "192.168.1.28")),
            .notFixedByInstalling(.tlsHostnameMismatch)
        )
        XCTAssertEqual(
            ServerCertificateCheck.from(try Self.trust(hostname: "hermes.home.arpa", on: Date(timeIntervalSince1970: 1830000000))),
            .notFixedByInstalling(.tlsBadDate)
        )
        XCTAssertEqual(
            ServerCertificateCheck.from(try Self.trust(hostname: "hermes.home.arpa", certificate: Self.weakKeyCertificate)),
            .notFixedByInstalling(.tlsNotStandardsCompliant)
        )
    }

    func testAChainWithItsRootOffersTheRootNotTheServerCertificate() throws {
        let check = ServerCertificateCheck.from(try Self.chainTrust([Self.caIssuedLeaf, Self.homeCA]))
        guard case .installable(let root) = check else { return XCTFail("expected installable, got \(check)") }
        XCTAssertEqual(root.subject, "Home Test CA")
        XCTAssertEqual(root.der, try XCTUnwrap(Data(base64Encoded: Self.homeCA)))
    }

    func testAServerThatDoesNotSendItsRootHasNothingToSave() throws {
        XCTAssertEqual(ServerCertificateCheck.from(try Self.chainTrust([Self.caIssuedLeaf])), .rootNotSent)
    }

    func testATrustedRootNeedsNothing() throws {
        XCTAssertEqual(ServerCertificateCheck.from(try Self.chainTrust([Self.caIssuedLeaf, Self.homeCA], anchored: true)), .alreadyTrusted)
    }

    func testProfileInstallsTheCertificateAsARoot() throws {
        let certificate = ServerCertificate(der: Data([1, 2, 3]), subject: "Home CA", isSelfSigned: true)
        let data = try ServerCertificateProfile.data(for: certificate, host: "hermes.home.arpa")
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(profile["PayloadVersion"] as? Int, 1)
        XCTAssertEqual(profile["PayloadDisplayName"] as? String, "Home CA")
        let identifier = try XCTUnwrap(profile["PayloadIdentifier"] as? String)
        XCTAssertTrue(identifier.hasPrefix("com.milim.relay.certificate."))
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(profile["PayloadUUID"] as? String)))
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        let root = try XCTUnwrap(payloads.first)
        XCTAssertEqual(root["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(root["PayloadContent"] as? Data, Data([1, 2, 3]))
        XCTAssertEqual(root["PayloadIdentifier"] as? String, identifier + ".root")
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(root["PayloadUUID"] as? String)))
    }

    func testTheSameCertificateKeepsOneIdentifierSoReinstallingReplacesIt() {
        let a = ServerCertificate(der: Data([1, 2, 3]), subject: "A", isSelfSigned: true)
        let b = ServerCertificate(der: Data([1, 2, 4]), subject: "A", isSelfSigned: true)
        XCTAssertEqual(ServerCertificateProfile.identifier(for: a), ServerCertificateProfile.identifier(for: a))
        XCTAssertNotEqual(ServerCertificateProfile.identifier(for: a), ServerCertificateProfile.identifier(for: b))
    }

    func testProfileFileNameKeepsOnlySafeCharacters() {
        XCTAssertEqual(ServerCertificateProfile.fileStem("hermes.home.arpa"), "hermes.home.arpa")
        XCTAssertEqual(ServerCertificateProfile.fileStem("fe80::1%en0"), "fe80--1-en0")
        XCTAssertEqual(ServerCertificateProfile.fileStem(""), "dashboard")
        XCTAssertEqual(ServerCertificateProfile.fileStem(String(repeating: "a", count: 253)).count, 100)
        XCTAssertEqual(ServerCertificateProfile.fileStem("é.example"), "-.example")
    }

    /// Conduit never accepts a certificate iOS refuses: no source hands
    /// URLSession or WebKit a credential for a server trust.
    func testNoSourceAcceptsAServerTrust() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConduitTests
            .deletingLastPathComponent() // repo root
        var offenders: [String] = []
        var scanned = 0
        for folder in ["Conduit", "Shared", "ConduitWatch", "ConduitNotificationService", "ConduitLocationPush", "ConduitShareExtension", "ConduitWidgets"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for forbidden in [".useCredential", "URLCredential(trust:", "SecTrustSetAnchorCertificates", "SecTrustSetExceptions"]
                where source.contains(forbidden) {
                    offenders.append("\(file.lastPathComponent): \(forbidden)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the sources were not found from \(root.path)")
        XCTAssertEqual(offenders, [])
    }

    // The fixtures ConnectionFailureTests evaluates.

    private static let weakKeyCertificate =
        "MIICRjCCAa+gAwIBAgIUZX74TVd1dVUBVU4lCZpyoKhJ3TowDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQaGVybWVzLmhvbWUuYXJwYTAeFw0yNjEwMjcyMjUzMTlaFw0yNzEwMjcyMjUzMTlaMBsx" +
        "GTAXBgNVBAMMEGhlcm1lcy5ob21lLmFycGEwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGBANs7" +
        "oerFw5oAfn+LXaXlT8GXUNzWVqliq044ozJ2mEPECUHKRfASsDnXopy1XyY0UZvx5t/lDdz9D/Wc" +
        "Mu6dJqUNqM/HzZGDT7zXi7xlkSLeBMee37vsM9v68ikOfeSiq2pY8qTgrUNz7S5wKkEd6W6KnuV9" +
        "ZFv6WMOljJvxaqFLAgMBAAGjgYYwgYMwHQYDVR0OBBYEFNnXDUX3LitLN0bYqHssxM9zXVfrMB8G" +
        "A1UdIwQYMBaAFNnXDUX3LitLN0bYqHssxM9zXVfrMA8GA1UdEwEB/wQFMAMBAf8wGwYDVR0RBBQw" +
        "EoIQaGVybWVzLmhvbWUuYXJwYTATBgNVHSUEDDAKBggrBgEFBQcDATANBgkqhkiG9w0BAQsFAAOB" +
        "gQADryXpuOqwRyPEreaXCNfJJ3gU4StW+5sWSxTu7nnV/TZrvXdmBNxYnN5XKnP7q0/mPgbQ5hM3" +
        "GJO4sHxTZkr9+w8ZszSX2RrAFQj4sicBKALHuzwELYAt4R2U58RjJAQGkaIsUQ6EDquQelQa6sLG" +
        "o4qwQkdsPK+H/W3lgNfKxg=="

    private static let certificate =
        "MIIDSzCCAjOgAwIBAgIUbQ5H1KF/cv+y+qpxtm1fYzTo6UgwDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQaGVybWVzLmhvbWUuYXJwYTAeFw0yNjEwMjcyMjQzMjNaFw0yNzEwMjcyMjQzMjNaMBsx" +
        "GTAXBgNVBAMMEGhlcm1lcy5ob21lLmFycGEwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB" +
        "AQCn8FAFlVnkm3yoeUtOPzIaCh5YqNWQGCm/lVqxUoX+SyhmQ/KqAfTo1mCwZLz0fJ5Z7ns5Q3hC" +
        "b02wNTR4tiMeY5H5fSR3WJv8atumhA+ElG9jdjKevcC0LbNRowPqEQ+o9uH3Xs+RsgEbknOIOohH" +
        "One9mYMx/UxCoi6YHVtAI72tpqLIqfpCl6GGZhMcLelvZMefw5oaLze4Z3JEOJe+KHMt2XVoYSAy" +
        "b9CLCDaAoA6MfK0PcxIH8ARwAcCNZkvGPxpM54j35DqCVK/L1ZMVXDv1ZDdUv+LN44iiNLx60UK8" +
        "jfiV0AGGXhbDd+VMxsEa8NKg/TmmHvy56l3CX28DAgMBAAGjgYYwgYMwHQYDVR0OBBYEFHOE5PWP" +
        "YymjHn5/sQHHv9fancasMB8GA1UdIwQYMBaAFHOE5PWPYymjHn5/sQHHv9fancasMA8GA1UdEwEB" +
        "/wQFMAMBAf8wGwYDVR0RBBQwEoIQaGVybWVzLmhvbWUuYXJwYTATBgNVHSUEDDAKBggrBgEFBQcD" +
        "ATANBgkqhkiG9w0BAQsFAAOCAQEAGjttsf+A0gisH98+TYGYSC6oLO7RyfcqZ4eTEQUfoQH87mhN" +
        "A8e/DAuo0xrG0bWvDTCKPAPzzVpuaHZmrsdBfQuWtsLHdvyaZg3PgPST8rKoFWoWFzCi5nAbWr/b" +
        "j18nkumUTjH1Mz8sCbUS8Pq7JIFfUpJNa3a2trao9EpUFlD4LrTF4GUnw8hx/CFuJnUKjA//i9qG" +
        "li7/gv0skSi3DfG3E0XFZc1d8hs4S2wkyOWBabyFc5UTJZ1muKuxDs6yq7oBkyN/ygGTOox2TlaS" +
        "7bcXGUqhpE+KZZOnVnR5ZQgKlW8gyT4YFLELv1cf7xA9+3wxNHlB4YM+ep1Jp4Smbg=="

    /// A root, "Home Test CA" (ten years, from 2026-11-03).
    private static let homeCA =
        "MIIDHzCCAgegAwIBAgIUTO5YPGFNfD2tpfPkeT76afemfzQwDQYJKoZIhvcNAQELBQAwFzEVMBMG" +
        "A1UEAwwMSG9tZSBUZXN0IENBMB4XDTI2MTEwMzIzMTI0MloXDTM2MTAzMTIzMTI0MlowFzEVMBMG" +
        "A1UEAwwMSG9tZSBUZXN0IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyc8vWX/I" +
        "OH6+88WQkqSkHDdJQ0BZ9HWKr0fMbafi309kYxt7KQlvO59erryzxxNdu7ckUz9ij7tmc1RLJV4z" +
        "agnBZmtBLtY42jWNw7bQyPmMjlbao+Rfnwkuo+smoKcOgBCTrSBd2tHibuoyUjJGYN5SZTNdI6Zx" +
        "6NWBdAqLU19DOMcmVVwgBSO3CCkwBrBEwZeZksfrUzPX059/ZFwTiJ5spDXU89ixiPov9u6nyt0n" +
        "nOI/Dn8Ze+CfGJ1Hlz7B3//+F7hZGDMwC+Q2ez4gmJi28U13P4jEc/haX0UmLthaYb49S1g4roqO" +
        "GDTsoIB/Ff22eqBXTBI4jn0BJY50iQIDAQABo2MwYTAdBgNVHQ4EFgQUxgEMChUzXr7tktNbuX8M" +
        "G9mhRU4wHwYDVR0jBBgwFoAUxgEMChUzXr7tktNbuX8MG9mhRU4wDwYDVR0TAQH/BAUwAwEB/zAO" +
        "BgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBABrTNQO+rBn3G8kKJrn2A4gucQrR6BKE" +
        "he/pLTJx3bs5Sb3gtSS9mZPr+oGjz9EMwRxAboTj+TVjelah/OHCDB1q11T59KZP4rvZNjGLQTS4" +
        "+wYjd/mxkkrMGAWhOXrnYSvnSKu01jq4RwDwB3K/0Go454NhJFAa/6RP9d+KHd1D28Nu+iyqQY1U" +
        "MLsOAQTNMLLdfClN8uTAH8S/dZF5/FD0G0DFfNR7HCHEkmcwAAbRSwkokIpzfKUMsI9C7sORGrSO" +
        "kCg2SmsxIwPRbmEGtf3q42To9YyIoI4TkIRsdZBtSaFN+G7vx/bbSF6u5uspYwHAszw1kYu4gcqy" +
        "ipfOSGg="

    /// hermes.home.arpa issued by homeCA (one year from 2026-11-03, serverAuth, SAN).
    private static let caIssuedLeaf =
        "MIIDTjCCAjagAwIBAgIUI2eKoqxSwI6gs9mFhgu4J6yqh0kwDQYJKoZIhvcNAQELBQAwFzEVMBMG" +
        "A1UEAwwMSG9tZSBUZXN0IENBMB4XDTI2MTEwMzIzMTI0MloXDTI3MTEwMzIzMTI0MlowGzEZMBcG" +
        "A1UEAwwQaGVybWVzLmhvbWUuYXJwYTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAMJ1" +
        "pfe8rOh0NvVeMG3RWHUmo7OzMRp+OifKZxlu7jckGJbHEpipFzyTInBy5/reKrSPj5rStPPbTAVy" +
        "2h1zXerJof63E1XlORVR7btVlOBPsx7KFh2IfQAR4VESZlgCfBss2qgmqsI+V6OeflFMUfVdcx5i" +
        "8rkIwkux7uLK5hTcJGLfErghhIjPaM66hbDTScUyoCjT8HkSIZs15vtBn1VpOo8D6yFo5EhPGwFD" +
        "THvpLPvR4u/bML9kg56TwZ2ezERwkBKbjQ2brE6cq9hJRXZzYea0EW7mB1ZwQ6tD1zqrAkKhx3dN" +
        "G/tGB16+JdBivd5442OzJ15Afs3oUXatZn8CAwEAAaOBjTCBijAJBgNVHRMEAjAAMBsGA1UdEQQU" +
        "MBKCEGhlcm1lcy5ob21lLmFycGEwEwYDVR0lBAwwCgYIKwYBBQUHAwEwCwYDVR0PBAQDAgWgMB0G" +
        "A1UdDgQWBBQ8UiYZ2FBZvhw5TPTDNsxsPWylFDAfBgNVHSMEGDAWgBTGAQwKFTNevu2S01u5fwwb" +
        "2aFFTjANBgkqhkiG9w0BAQsFAAOCAQEAvokJ8Rdkm1tGZ4XSjLnQZRKJbfd3D4UaM9diGObjf4nd" +
        "yB5oYKEtrW4lvCyv/PFSsUq5oq061RtvNWep1PIL05L0BNxzRUP41F2WVLzxxHQQrVrmoErFbM+n" +
        "y84Osb0G3RcYahQxupsUUoARLwgyyY5RtcQX/rY87dmPGp1ZYsU083g6ZoXqNidX+IcIBzscyqRM" +
        "Foify50BGZexh7Iw46XuH3KryfiUWtl8s5nUwRikmLMfS5b+mJc+GJEZed+iE/4rHdMiNdL6ZUin" +
        "oR4BzpwX0tQLSqZQKzKKcUuySsLgU2VSZk+XkejfoQfiaB58GCjkLY1g0V7V2vNCqsBOnw=="

    private static func chainTrust(_ chain: [String], anchored: Bool = false) throws -> SecTrust {
        let certificates = try chain.map { base64 in
            try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: base64)) as CFData))
        }
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, "hermes.home.arpa" as CFString), &trust), errSecSuccess)
        let made = try XCTUnwrap(trust)
        if anchored {
            XCTAssertEqual(SecTrustSetAnchorCertificates(made, [certificates[certificates.count - 1]] as CFArray), errSecSuccess)
        }
        SecTrustSetVerifyDate(made, Date(timeIntervalSince1970: 1796000000) as CFDate)
        return made
    }

    private static func trust(
        hostname: String, certificate base64: String = certificate,
        on day: Date = Date(timeIntervalSince1970: 1793145600)
    ) throws -> SecTrust {
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, hostname as CFString), &trust), errSecSuccess)
        let made = try XCTUnwrap(trust)
        SecTrustSetVerifyDate(made, day as CFDate)
        return made
    }
}
