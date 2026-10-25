import Foundation

/// Error text that is safe to log with `privacy: .public`: every URL in it
/// becomes `<url>` and every host named without one `<host>`. A URLError's
/// description carries the failing request's address (a dashboard, relay or
/// speech server, with its path and query), a TLS error names the host it
/// distrusts, and a public log line is readable by anyone handed a
/// sysdiagnose.
enum LogRedaction {
    /// `String(describing:)` of the error, URLs replaced.
    static func describing(_ error: Error) -> String {
        redactingURLs(String(describing: error))
    }

    /// The same for an error that may be absent ("nil").
    static func describing(_ error: Error?) -> String {
        error.map { describing($0) } ?? "nil"
    }

    /// The error's localized description, URLs replaced.
    static func message(_ error: Error) -> String {
        redactingURLs(error.localizedDescription)
    }

    /// URLs first, then the hosts left outside them.
    static func redactingURLs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let withoutURLs = urlPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<url>")
        return redactingHosts(withoutURLs)
    }

    /// Hosts named without a scheme: the one a TLS error says is
    /// "pretending to be “host”", an IPv4 or bracketed IPv6 address, a
    /// dotted name with a port (any case), and a lowercase dotted name
    /// ending in letters, each with the path and query after it. Type names
    /// (`HermesClientError.timeout`), versions of up to three parts and
    /// prose are kept, and so is a file name with one of the extensions
    /// below (`config.yaml`); any other file name reads as a host. An
    /// unbracketed IPv6 address (`fe80::1`) is not matched.
    static func redactingHosts(_ text: String) -> String {
        let nsText = text as NSString
        var result = text
        let matches = hostPattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            // The extension of the name itself, not of a path after it.
            let name = token.prefix { $0 != "/" && $0 != "?" }
            if !name.contains(":"), let last = name.split(separator: ".").last,
               fileExtensions.contains(last.lowercased()) { continue }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "<host>")
        }
        return result
    }

    /// A scheme, "://" and everything up to whitespace, a quote, an angle
    /// or curly bracket. It never ends on the punctuation that follows a URL
    /// in prose or in NSError's userInfo list (", ", ".", ";", ")", "]"),
    /// but keeps it inside one, and covers IPv6 literal hosts.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>{}]*[^\s"'<>{},;.)\]]"#
    )

    /// A localized TLS error in another language quotes the host its own
    /// way: there a single-label host (`localhost`) or an uppercase name
    /// without a port still reads as written.
    private static let hostPattern = try! NSRegularExpression(
        pattern: #"(?<=pretending to be “)[^”\s]+(?=”)"#
            + #"|(?<![\w.\-:/])(?:"#
            + #"\[[0-9A-Fa-f.%]*:[0-9A-Za-z:.%]*\](?::\d{1,5})?"#
            + #"|(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?"#
            + #"|(?:[A-Za-z0-9_](?:[A-Za-z0-9_\-]*[A-Za-z0-9_])?\.)+[A-Za-z](?:[A-Za-z0-9\-]*[A-Za-z0-9])?:\d{1,5}"#
            + #"|(?:[a-z0-9_](?:[a-z0-9_\-]*[a-z0-9_])?\.)+[a-z]{2,63}"#
            + #")(?![\w\-]|\.[A-Za-z0-9])"#
            + #"(?:[/?][^\s"'<>{}]*[^\s"'<>{},;.)\]])?"#
    )

    /// Extensions of files an error may name that no domain ends in
    /// (`md`, `py` and `zip` are domains, so those names are redacted).
    private static let fileExtensions: Set<String> = [
        "caf", "csv", "gif", "heic", "html", "jpeg", "jpg", "json", "log", "pdf", "plist",
        "png", "sqlite", "swift", "tar", "toml", "txt", "wav", "xcconfig", "xml", "yaml", "yml",
    ]
}
