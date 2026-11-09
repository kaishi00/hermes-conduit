"""Linux source-contract checks for #1921; not behaviour or SwiftUI evidence.

These read the sources for which reads each route performs and for the
deferred notification read. They cannot run the app: no Swift toolchain on
this host, and the tap, the capability arriving mid-save and the list's cron
refresh are only observable on a simulator or a device.
"""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP_STATE = ROOT / "Conduit/Services/AppState.swift"
CRON_NOTIFICATIONS = ROOT / "Conduit/Services/AppState+CronNotifications.swift"
SHELL = ROOT / "Conduit/Views/V2/V2Shell.swift"


def function(source, signature):
    """A function's body, from its declaration to the next one at the same depth."""
    start = source.index(signature)
    end = source.find("\n    func ", start + 1)
    return source[start:end if end != -1 else len(source)]


class ScheduledTabReadsSourceContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app_state = APP_STATE.read_text()
        cls.notifications = CRON_NOTIFICATIONS.read_text()
        cls.shell = SHELL.read_text()

    def test_opening_the_tab_reads_the_jobs_and_not_the_catalogue(self):
        body = function(self.app_state, "func refreshScheduledContent() async {")
        self.assertIn("loadCronJobs()", body)
        self.assertIn("refreshCronNotifications()", body)
        # Any catalogue read here would restore the read this PR removed, so
        # every route to it is refused, not just the pull's full replace.
        for read in ("refreshSessionCatalog", "refreshNewestSessionCatalogPage",
                     "refreshCronContent", "loadSessions"):
            self.assertNotIn(read, body)

    def test_show_runs_in_chats_reads_the_catalogue_on_the_tap(self):
        body = function(self.shell, "private func showScheduledRuns() {")
        switched = body.index("selectTab(.chats)")
        read = body.index("appState.refreshNewestSessionCatalogPage()")
        self.assertLess(switched, read)
        # Not the pull's full replace: a tap forces the newest page and the
        # cron rows, and leaves the history walk to its own interval.
        self.assertNotIn("refreshSessionCatalog()", body)

    def test_a_read_asked_for_during_a_save_is_not_dropped(self):
        body = function(self.notifications, "func refreshCronNotifications() async {")
        guard = body.index("guard cronNotificationsChangingJobID == nil else {")
        deferred = body.index("cronNotificationsReadDeferred = true", guard)
        self.assertLess(guard, deferred)

    def test_the_save_ends_by_running_the_deferred_read(self):
        body = function(self.notifications, "func setCronJobNotifies(")
        defer = body.index("defer {")
        retry = body.index("if cronNotificationsReadDeferred", defer)
        self.assertLess(defer, retry)
        helper = function(self.notifications, "private func refreshCronNotificationsAfterSave()")
        self.assertIn("cronNotificationsReadDeferred = false", helper)


if __name__ == "__main__":
    unittest.main()
