"""Checks the icloudpd launcher's indexing patch with a fake service. No network, no account.

Run with the bundled runtime (scripts/test-bridge.sh does this):
  Vendor/icloudpd-runtime/python/bin/python3.13 -I -B test_launcher.py PATH/TO/run_icloudpd.py
"""

import importlib.util
import json
import sys
import unittest

LAUNCHER_PATH = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("run_icloudpd", LAUNCHER_PATH)
launcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launcher)  # __name__ is not "__main__", so the CLI does not run

from pyicloud_ipd.exceptions import PyiCloudServiceNotActivatedException  # noqa: E402
from pyicloud_ipd.services import photos  # noqa: E402


class FakeResponse:
    def __init__(self, data):
        self._data = data

    def json(self):
        return self._data


class FakeSession:
    """Answers CheckIndexingState with `state`, or raises `error`, as session.py does."""

    def __init__(self, state=None, error=None):
        self.state = state
        self.error = error

    def post(self, url, data=None, headers=None):
        if self.error is not None:
            raise self.error
        assert json.loads(data)["query"]["recordType"] == "CheckIndexingState"
        return FakeResponse({"records": [{"fields": {"state": {"value": self.state}}}]})


def library(session):
    return photos.PhotoLibrary("https://fake", {"dsid": "1"}, session, {"zoneName": "PrimarySync"}, "private")


class LauncherIndexingTests(unittest.TestCase):
    def test_running_is_tolerated_with_a_warning(self):
        with self.assertLogs("icloudpd", level="WARNING") as logs:
            lib = library(FakeSession(state="RUNNING"))
        # Every attribute is set before the check, so the library is usable.
        self.assertEqual(lib.service_endpoint, "https://fake")
        self.assertEqual(lib.params, {"dsid": "1"})
        self.assertEqual(lib.zone_id, {"zoneName": "PrimarySync"})
        self.assertEqual(lib.library_type, "private")
        self.assertIn("still indexing this library", logs.output[0])

    def test_finished_is_silent(self):
        lib = library(FakeSession(state="FINISHED"))
        self.assertEqual(lib.library_type, "private")

    def test_setup_not_complete_is_still_raised(self):
        error = PyiCloudServiceNotActivatedException(
            "Apple iCloud setup is not complete. Please log into https://icloud.com/", "ZONE_NOT_FOUND"
        )
        with self.assertRaises(PyiCloudServiceNotActivatedException) as raised:
            library(FakeSession(error=error))
        self.assertIn("setup is not complete", str(raised.exception))

    def test_other_errors_are_still_raised(self):
        with self.assertRaises(PyiCloudServiceNotActivatedException):
            library(FakeSession(error=PyiCloudServiceNotActivatedException("Some other reason", None)))

    def test_patch_is_applied_once(self):
        launcher.tolerate_indexing_state()
        self.assertTrue(getattr(photos.PhotoLibrary.__init__, "_uncloud", False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
