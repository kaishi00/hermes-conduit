"""Extensions that reach the dashboard allow what the app allows (issue 2028).

App Transport Security is read from each bundle's own Info.plist, so an
extension without the app's block can't reach a plain-HTTP Tailscale or LAN
dashboard the app connects to: the Location Push extension's maps fetch
failed with NSURLErrorDomain -1022 there.
"""

from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Every app extension target in project.yml and its sources; a new one goes
# here. The Watch app isn't one: it opens only wss sockets, never the dashboard
# over http.
EXTENSIONS = {
    "ConduitLocationPush": "ConduitLocationPush",
    "ConduitNotificationService": "ConduitNotificationService",
    "ConduitShareExtension": "ConduitShareExtension",
    "ConduitWidgets": "ConduitWidgets",
    # No requests of its own.
    "ConduitWatchWidgets": "ConduitWatch/Widgets",
}
# What sends a request to the dashboard. Only the target's own directory is
# scanned; a Shared/ file it compiles (LocationHostClient) is named here.
HOST_REQUESTS = re.compile(r"\b(URLSession|URLRequest|LocationHostClient)\b")


def info(directory):
    path = ROOT / directory / "Info.plist"
    if not path.exists():
        return {}
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def reaches_host(directory):
    return any(HOST_REQUESTS.search(path.read_text(encoding="utf-8")) for path in (ROOT / directory).rglob("*.swift"))


class ExtensionTransportSecurityTests(unittest.TestCase):
    def test_extensions_that_reach_the_dashboard_allow_what_the_app_allows(self):
        app = info("Conduit")["NSAppTransportSecurity"]
        self.assertTrue(reaches_host("ConduitLocationPush"))
        for target, directory in EXTENSIONS.items():
            if not reaches_host(directory):
                continue
            with self.subTest(extension=target):
                self.assertEqual(info(directory).get("NSAppTransportSecurity"), app)

    def test_every_app_extension_target_is_checked(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        targets = re.findall(r"^  (\w+):\n(?:    #.*\n)*    type: app-extension\n", project, re.MULTILINE)
        self.assertTrue(targets)
        self.assertEqual(set(targets) - set(EXTENSIONS), set())

    def test_no_extension_allows_arbitrary_loads(self):
        for target, directory in EXTENSIONS.items():
            with self.subTest(extension=target):
                ats = info(directory).get("NSAppTransportSecurity") or {}
                self.assertNotEqual(ats.get("NSAllowsArbitraryLoads"), True)


if __name__ == "__main__":
    unittest.main()
