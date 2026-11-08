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
EXTENSIONS = ("ConduitLocationPush", "ConduitNotificationService", "ConduitShareExtension", "ConduitWidgets")
# What sends a request to the dashboard from an extension's own sources.
HOST_REQUESTS = re.compile(r"\b(URLSession|URLRequest|LocationHostClient)\b")


def info(target):
    with open(ROOT / target / "Info.plist", "rb") as handle:
        return plistlib.load(handle)


def reaches_host(target):
    return any(HOST_REQUESTS.search(path.read_text()) for path in (ROOT / target).rglob("*.swift"))


class ExtensionTransportSecurityTests(unittest.TestCase):
    def test_extensions_that_reach_the_dashboard_allow_what_the_app_allows(self):
        app = info("Conduit")["NSAppTransportSecurity"]
        self.assertTrue(reaches_host("ConduitLocationPush"))
        for target in EXTENSIONS:
            if not reaches_host(target):
                continue
            with self.subTest(extension=target):
                self.assertEqual(info(target).get("NSAppTransportSecurity"), app)

    def test_no_extension_allows_arbitrary_loads(self):
        for target in EXTENSIONS:
            with self.subTest(extension=target):
                ats = info(target).get("NSAppTransportSecurity") or {}
                self.assertNotEqual(ats.get("NSAllowsArbitraryLoads"), True)


if __name__ == "__main__":
    unittest.main()
