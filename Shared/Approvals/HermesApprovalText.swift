import Foundation

/// Hermes' own words on an approval, in the App Language (#1589).
///
/// Hermes writes an approval's explanation in English: a flagged command's
/// pattern ("recursive delete"), the protected-file gate's warning, and the
/// consent prompts for scripts, MCP servers, plugins and a saved card. The
/// app knows those texts and shows each in the user's language, filling in
/// what Hermes put in them (file names, servers, tools) as sent. Anything
/// else, a plugin's own reason or a text a newer Hermes wrote differently,
/// shows as Hermes sent it, so nothing is ever hidden or reworded.
///
/// Only for what the user reads: the chat card, rooms, a voice mode's
/// screen and what it says, the notification and the Watch. Matching
/// (which request a card answers) and what models are told keep Hermes'
/// own text. Callers still pass the result through
/// `ApprovalDisplayText.revealingHidden` where they did before.
///
/// Compiled into the app, the Notification Service Extension and the Watch,
/// each with its own `AppLocalization` and String Catalog.
enum HermesApprovalText {
    /// An approval's description, in the App Language when Hermes wrote it.
    static func description(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = pattern(trimmed) { return known }
        if let targets = between(trimmed,
                                 "Write to protected agent-instruction file(s): ",
                                 ". These files steer future agent behavior; approval is always required (not bypassed by auto-approve).") {
            return AppLocalization.string("Write to protected agent-instruction file(s): \(targets). These files steer future agent behavior; approval is always required (not bypassed by auto-approve).")
        }
        if trimmed == "execute_code script execution. The script can spawn subprocesses or mutate files without passing through terminal command approval; approval is one-shot for this run." {
            return AppLocalization.string("execute_code script execution. The script can spawn subprocesses or mutate files without passing through terminal command approval; approval is one-shot for this run.")
        }
        if trimmed == "The agent wants to enter your saved card details into this checkout page. The card number and CVC never enter the conversation. Approve only if you intend to pay here." {
            return AppLocalization.string("The agent wants to enter your saved card details into this checkout page. The card number and CVC never enter the conversation. Approve only if you intend to pay here.")
        }
        if case let (server, tool)? = pair(trimmed, "Server '", "' is configured 'trust: untrusted'. Approve to run '", "' once, or deny to block it.") {
            return AppLocalization.string("Server '\(server)' is configured 'trust: untrusted'. Approve to run '\(tool)' once, or deny to block it.")
        }
        if case let (server, tool)? = pair(trimmed, "Server '", "' is configured 'trust: untrusted'. Approve to run '", "' once, for this session, or always, or deny to block it.") {
            return AppLocalization.string("Server '\(server)' is configured 'trust: untrusted'. Approve to run '\(tool)' once, for this session, or always, or deny to block it.")
        }
        if case let (server, tool)? = pair(trimmed, "Server '", "' declares a spend limit per chat. Approve to run '", "' once (every further paid call in this chat asks again), or deny to block it.") {
            return AppLocalization.string("Server '\(server)' declares a spend limit per chat. Approve to run '\(tool)' once (every further paid call in this chat asks again), or deny to block it.")
        }
        if let tool = between(trimmed, "Plugin requires approval for ", ""), isName(tool) {
            return AppLocalization.string("Plugin requires approval for \(tool)")
        }
        if let action = between(trimmed, "Allow computer_use to perform `", "`?"), isName(action) {
            return AppLocalization.string("Allow computer_use to perform `\(action)`?")
        }
        if let directory = between(trimmed, "Codex requests exec in ", ""), isName(directory) {
            return AppLocalization.string("Codex requests exec in \(directory)")
        }
        if trimmed == "Hermes needs your approval. Open Conduit for details." {
            // The plugin's own line when Show in notifications hides the
            // request (events.py REDACTED_APPROVAL_TEXT), on the card a
            // push makes before the chat loads.
            return AppLocalization.string("Hermes needs your approval. Open Conduit for details.")
        }
        if let flag = between(trimmed, "arbitrary program execution via ", ""),
           case let words = flag.split(separator: " ", omittingEmptySubsequences: false),
           words.count == 2, words.allSatisfy({ isName(String($0)) }) {
            return AppLocalization.string("arbitrary program execution via \(flag)")
        }
        return text
    }

    /// An approval's command: the protected-file gate's `<write to …>`
    /// stands for the write in the App Language; a real command is data and
    /// comes back as sent.
    static func command(_ text: String) -> String {
        // Only the gate's own shape, names joined by ", ": anything else in
        // it is a real command and shows as sent.
        guard let targets = between(text, "<write to ", ">"),
              targets.components(separatedBy: ", ").allSatisfy({ target in
                  isName(target) && !target.contains(where: { "<>|;&'\"$,".contains($0) })
              })
        else { return text }
        return AppLocalization.string("<write to \(targets)>")
    }

    /// What's between a known start and end, when there is something.
    private static func between(_ text: String, _ prefix: String, _ suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix),
              text.count > prefix.count + suffix.count else { return nil }
        return String(text.dropFirst(prefix.count).dropLast(suffix.count))
    }

    /// One word, as a tool, a directory, an action or a flag Hermes names: a text
    /// that only starts like Hermes' own (a plugin's own reason, "Plugin
    /// requires approval for deleting the cache") isn't one of its texts.
    private static func isName(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "`" }
    }

    /// The two names in a text of the shape prefix, first, middle, second,
    /// suffix; nil when the middle doesn't split it in exactly two.
    private static func pair(_ text: String, _ prefix: String, _ middle: String, _ suffix: String) -> (String, String)? {
        guard let inner = between(text, prefix, suffix) else { return nil }
        let parts = inner.components(separatedBy: middle)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// Hermes' descriptions of a flagged command (tools/approval_detection.py:
    /// DANGEROUS_PATTERNS and the parser's own findings).
    private static func pattern(_ text: String) -> String? {
        switch text {
        case "delete in root path": return AppLocalization.string("delete in root path")
        case "recursive delete": return AppLocalization.string("recursive delete")
        case "recursive delete (long flag)": return AppLocalization.string("recursive delete (long flag)")
        case "recursive delete (flags after operands)": return AppLocalization.string("recursive delete (flags after operands)")
        case "Windows cmd destructive delete": return AppLocalization.string("Windows cmd destructive delete")
        case "Windows PowerShell destructive delete": return AppLocalization.string("Windows PowerShell destructive delete")
        case "PowerShell encoded command execution": return AppLocalization.string("PowerShell encoded command execution")
        case "PowerShell destructive delete (Remove-Item)": return AppLocalization.string("PowerShell destructive delete (Remove-Item)")
        case "Windows destructive delete (recursive/quiet switch)": return AppLocalization.string("Windows destructive delete (recursive/quiet switch)")
        case "pipe remote content to PowerShell (iwr | iex)": return AppLocalization.string("pipe remote content to PowerShell (iwr | iex)")
        case "execute remote content via Invoke-Expression": return AppLocalization.string("execute remote content via Invoke-Expression")
        case "force kill processes (taskkill /F)": return AppLocalization.string("force kill processes (taskkill /F)")
        case "force kill processes (Stop-Process -Force)": return AppLocalization.string("force kill processes (Stop-Process -Force)")
        case "format filesystem (Format-Volume)": return AppLocalization.string("format filesystem (Format-Volume)")
        case "wipe disk (Clear-Disk)": return AppLocalization.string("wipe disk (Clear-Disk)")
        case "disk partitioning (diskpart)": return AppLocalization.string("disk partitioning (diskpart)")
        case "format drive (format.com)": return AppLocalization.string("format drive (format.com)")
        case "wipe free space (cipher /w)": return AppLocalization.string("wipe free space (cipher /w)")
        case "grant Everyone access (icacls)": return AppLocalization.string("grant Everyone access (icacls)")
        case "reset ACLs recursively (icacls /reset)": return AppLocalization.string("reset ACLs recursively (icacls /reset)")
        case "delete volume shadow copies (vssadmin)": return AppLocalization.string("delete volume shadow copies (vssadmin)")
        case "delete backups (wbadmin)": return AppLocalization.string("delete backups (wbadmin)")
        case "modify boot configuration (bcdedit /set)": return AppLocalization.string("modify boot configuration (bcdedit /set)")
        case "registry delete (reg delete)": return AppLocalization.string("registry delete (reg delete)")
        case "registry value delete (Remove-ItemProperty -Force)": return AppLocalization.string("registry value delete (Remove-ItemProperty -Force)")
        case "force stop service (Stop-Service -Force)": return AppLocalization.string("force stop service (Stop-Service -Force)")
        case "stop/delete service (sc)": return AppLocalization.string("stop/delete service (sc)")
        case "access to SSH keys (Windows path)": return AppLocalization.string("access to SSH keys (Windows path)")
        case "access to Hermes secrets (Windows path)": return AppLocalization.string("access to Hermes secrets (Windows path)")
        case "world/other-writable permissions": return AppLocalization.string("world/other-writable permissions")
        case "recursive world/other-writable (long flag)": return AppLocalization.string("recursive world/other-writable (long flag)")
        case "recursive chown to root": return AppLocalization.string("recursive chown to root")
        case "recursive chown to root (long flag)": return AppLocalization.string("recursive chown to root (long flag)")
        case "format filesystem": return AppLocalization.string("format filesystem")
        case "disk copy": return AppLocalization.string("disk copy")
        case "write to block device": return AppLocalization.string("write to block device")
        case "SQL DROP": return AppLocalization.string("SQL DROP")
        case "SQL DELETE without WHERE": return AppLocalization.string("SQL DELETE without WHERE")
        case "SQL TRUNCATE": return AppLocalization.string("SQL TRUNCATE")
        case "overwrite system config": return AppLocalization.string("overwrite system config")
        case "stop/restart system service": return AppLocalization.string("stop/restart system service")
        case "kill all processes": return AppLocalization.string("kill all processes")
        case "force kill processes": return AppLocalization.string("force kill processes")
        case "force kill processes (killall -KILL)": return AppLocalization.string("force kill processes (killall -KILL)")
        case "force kill processes (killall -s KILL)": return AppLocalization.string("force kill processes (killall -s KILL)")
        case "kill processes by regex (killall -r)": return AppLocalization.string("kill processes by regex (killall -r)")
        case "fork bomb": return AppLocalization.string("fork bomb")
        case "pipe remote content to shell": return AppLocalization.string("pipe remote content to shell")
        case "execute remote script via process substitution": return AppLocalization.string("execute remote script via process substitution")
        case "execute remote content via command substitution": return AppLocalization.string("execute remote content via command substitution")
        case "cloud metadata endpoint access (instance credentials)": return AppLocalization.string("cloud metadata endpoint access (instance credentials)")
        case "pipe decoded content to shell (possible command obfuscation)": return AppLocalization.string("pipe decoded content to shell (possible command obfuscation)")
        case "pipe xxd-decoded content to shell (possible command obfuscation)": return AppLocalization.string("pipe xxd-decoded content to shell (possible command obfuscation)")
        case "pipe tr-transformed output to shell (possible command obfuscation)": return AppLocalization.string("pipe tr-transformed output to shell (possible command obfuscation)")
        case "pipe openssl-decoded content to shell (possible command obfuscation)": return AppLocalization.string("pipe openssl-decoded content to shell (possible command obfuscation)")
        case "upload a secret or credential file via curl/wget (possible exfiltration)": return AppLocalization.string("upload a secret or credential file via curl/wget (possible exfiltration)")
        case "pipe a credential file into a curl/wget upload (possible exfiltration)": return AppLocalization.string("pipe a credential file into a curl/wget upload (possible exfiltration)")
        case "invisible or bidirectional Unicode control character (possible obfuscation)": return AppLocalization.string("invisible or bidirectional Unicode control character (possible obfuscation)")
        case "overwrite system file via tee": return AppLocalization.string("overwrite system file via tee")
        case "overwrite system file via redirection": return AppLocalization.string("overwrite system file via redirection")
        case "overwrite project env/config via tee": return AppLocalization.string("overwrite project env/config via tee")
        case "overwrite project env/config via redirection": return AppLocalization.string("overwrite project env/config via redirection")
        case "xargs with rm": return AppLocalization.string("xargs with rm")
        case "find -exec/-execdir rm": return AppLocalization.string("find -exec/-execdir rm")
        case "find dynamic shell word may expand to destructive flag": return AppLocalization.string("find dynamic shell word may expand to destructive flag")
        case "find -delete": return AppLocalization.string("find -delete")
        case "dynamic shell word may expand to arbitrary program execution flag": return AppLocalization.string("dynamic shell word may expand to arbitrary program execution flag")
        case "stop/restart hermes gateway (kills running agents)": return AppLocalization.string("stop/restart hermes gateway (kills running agents)")
        case "hermes update (restarts gateway, kills running agents)": return AppLocalization.string("hermes update (restarts gateway, kills running agents)")
        case "docker with remote daemon redirect (-H/--host)": return AppLocalization.string("docker with remote daemon redirect (-H/--host)")
        case "docker with daemon redirect (--context: alternate daemon)": return AppLocalization.string("docker with daemon redirect (--context: alternate daemon)")
        case "docker context use (switches default daemon for future commands)": return AppLocalization.string("docker context use (switches default daemon for future commands)")
        case "podman with remote daemon redirect (--url/--connection/--identity)": return AppLocalization.string("podman with remote daemon redirect (--url/--connection/--identity)")
        case "podman remote mode (-r/--remote: remote daemon)": return AppLocalization.string("podman remote mode (-r/--remote: remote daemon)")
        case "docker/podman daemon redirect via environment (DOCKER_HOST/CONTAINER_HOST)": return AppLocalization.string("docker/podman daemon redirect via environment (DOCKER_HOST/CONTAINER_HOST)")
        case "docker compose restart/stop/kill/down (container lifecycle)": return AppLocalization.string("docker compose restart/stop/kill/down (container lifecycle)")
        case "docker restart/stop/kill (container lifecycle)": return AppLocalization.string("docker restart/stop/kill (container lifecycle)")
        case "start gateway outside systemd (use 'systemctl --user restart hermes-gateway')": return AppLocalization.string("start gateway outside systemd (use 'systemctl --user restart hermes-gateway')")
        case "kill hermes/gateway process (self-termination)": return AppLocalization.string("kill hermes/gateway process (self-termination)")
        case "kill process via pgrep/pidof expansion (self-termination)": return AppLocalization.string("kill process via pgrep/pidof expansion (self-termination)")
        case "kill process via backtick pgrep/pidof expansion (self-termination)": return AppLocalization.string("kill process via backtick pgrep/pidof expansion (self-termination)")
        case "stop/restart hermes launchd service (kills running agents)": return AppLocalization.string("stop/restart hermes launchd service (kills running agents)")
        case "copy/move file into system config path": return AppLocalization.string("copy/move file into system config path")
        case "overwrite project env/config file": return AppLocalization.string("overwrite project env/config file")
        case "copy/move file into sensitive credential/SSH/shell-rc path": return AppLocalization.string("copy/move file into sensitive credential/SSH/shell-rc path")
        case "in-place edit of sensitive credential/SSH/shell-rc path": return AppLocalization.string("in-place edit of sensitive credential/SSH/shell-rc path")
        case "in-place edit of sensitive credential/SSH/shell-rc path (long flag)": return AppLocalization.string("in-place edit of sensitive credential/SSH/shell-rc path (long flag)")
        case "in-place edit of sensitive credential/SSH/shell-rc path (perl/ruby)": return AppLocalization.string("in-place edit of sensitive credential/SSH/shell-rc path (perl/ruby)")
        case "in-place edit of system config": return AppLocalization.string("in-place edit of system config")
        case "in-place edit of system config (long flag)": return AppLocalization.string("in-place edit of system config (long flag)")
        case "in-place edit of Hermes config/env": return AppLocalization.string("in-place edit of Hermes config/env")
        case "in-place edit of Hermes config/env (long flag)": return AppLocalization.string("in-place edit of Hermes config/env (long flag)")
        case "in-place edit of Hermes config/env (perl/ruby)": return AppLocalization.string("in-place edit of Hermes config/env (perl/ruby)")
        case "shell execution via heredoc": return AppLocalization.string("shell execution via heredoc")
        case "git reset --hard (destroys uncommitted changes)": return AppLocalization.string("git reset --hard (destroys uncommitted changes)")
        case "git force push (rewrites remote history)": return AppLocalization.string("git force push (rewrites remote history)")
        case "git force push short flag (rewrites remote history)": return AppLocalization.string("git force push short flag (rewrites remote history)")
        case "git clean with force (deletes untracked files)": return AppLocalization.string("git clean with force (deletes untracked files)")
        case "git branch force delete": return AppLocalization.string("git branch force delete")
        case "git branch force delete (long flags)": return AppLocalization.string("git branch force delete (long flags)")
        case "git branch force delete (long flags, force-first)": return AppLocalization.string("git branch force delete (long flags, force-first)")
        case "chmod +x followed by immediate execution": return AppLocalization.string("chmod +x followed by immediate execution")
        case "sudo with privilege flag (stdin/askpass/shell/list)": return AppLocalization.string("sudo with privilege flag (stdin/askpass/shell/list)")
        case "sudo with combined-flag privilege escalation": return AppLocalization.string("sudo with combined-flag privilege escalation")
        case "package manager uninstall": return AppLocalization.string("package manager uninstall")
        case "command parser limit exceeded": return AppLocalization.string("command parser limit exceeded")
        case "command parser limit or malformed executable payload": return AppLocalization.string("command parser limit or malformed executable payload")
        case "stop/restart hermes gateway via shell-spliced verb (kills running agents)": return AppLocalization.string("stop/restart hermes gateway via shell-spliced verb (kills running agents)")
        case "script execution via -e/-c flag": return AppLocalization.string("script execution via -e/-c flag")
        case "shell command via -c/-lc flag": return AppLocalization.string("shell command via -c/-lc flag")
        case "script execution via heredoc": return AppLocalization.string("script execution via heredoc")
        default: return nil
        }
    }
}
