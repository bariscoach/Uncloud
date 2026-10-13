"""Tests for UncloudTests/Fakes/fake_bridge.py: its ranks, prepend and delete, startRank, throttle and paths.

Run with the bundled interpreter, the way scripts/test-bridge.sh runs test_bridge.py:
  Vendor/icloudpd-runtime/python/bin/python3.13 -I -B UncloudTests/Bridge/test_fake_bridge.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE = os.path.join(HERE, "..", "Fakes", "fake_bridge.py")


class Session:
    """One launch of the fake, spoken to over its JSON-lines protocol."""

    def __init__(self, *options):
        self.process = subprocess.Popen(
            [sys.executable, "-I", "-B", FAKE, *options, "--", "-u", "someone@example.com"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.ready = self.read()

    def read(self):
        line = self.process.stdout.readline()
        if not line:
            raise AssertionError("the fake bridge closed its output")
        return json.loads(line)

    def call(self, message, terminal):
        """Sends a request and returns every reply with its ID up to and including the terminal event."""
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        replies = []
        while True:
            reply = self.read()
            if reply.get("id") != message["id"]:
                continue
            replies.append(reply)
            if reply.get("event") in terminal:
                return replies

    def page(self, offset, limit=200):
        replies = self.call({"cmd": "page", "id": "p", "offset": offset, "limit": limit}, {"page"})
        return replies[-1]["items"]

    def download(self, dest, **fields):
        request = {"cmd": "download", "id": "d", "dest": dest, "mode": "allExcept", "ids": [], **fields}
        return self.call(request, {"done", "error"})

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()
        return self.process.returncode


def run_fake(*options):
    """Launches the fake with options that must fail; returns (exit status, stderr)."""
    result = subprocess.run([sys.executable, "-I", "-B", FAKE, *options, "--", "-u", "x"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10)
    return result.returncode, result.stderr


class FakeBridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.state = os.path.join(self.root, "library.json")
        self.log = os.path.join(self.root, "launches.log")
        self.dest = os.path.join(self.root, "dest")
        self.sessions = []

    def tearDown(self):
        for session in self.sessions:
            try:
                session.close()
            except Exception:  # noqa: BLE001
                session.process.kill()
        self.tmp.cleanup()

    def start(self, *options):
        session = Session(*options, "--rate", "0", "--launch-log", self.log)
        self.sessions.append(session)
        return session

    def launch_lines(self):
        with open(self.log, encoding="utf-8") as handle:
            return [line.rstrip("\n") for line in handle]

    def test_default_library_puts_asset_i_at_rank_i(self):
        session = self.start("--total", "5")
        self.assertEqual(session.ready["count"], 5)
        items = session.page(0, limit=3)
        self.assertEqual([item["id"] for item in items], ["asset-0", "asset-1", "asset-2"])
        self.assertEqual([item["rank"] for item in items], [0, 1, 2])
        self.assertEqual(items[0]["filename"], "IMG_000000.JPG")
        self.assertEqual(items[0]["size"], 1000)
        self.assertEqual([item["id"] for item in session.page(4)], ["asset-4"])

    def test_insert_at_zero_prepends_and_shifts_every_rank(self):
        session = self.start("--total", "3", "--state", self.state, "--insert-at", "0")
        self.assertEqual(session.ready["count"], 4)
        items = session.page(0)
        self.assertEqual([item["id"] for item in items], ["asset-3", "asset-0", "asset-1", "asset-2"])
        self.assertEqual([item["rank"] for item in items], [0, 1, 2, 3])
        self.assertEqual(items[0]["filename"], "IMG_000003.JPG")

    def test_insert_in_the_middle_and_the_new_order_survives_a_relaunch(self):
        self.start("--total", "4", "--state", self.state, "--insert-at", "2", "--insert-count", "2").close()
        session = self.start("--total", "999", "--state", self.state)
        self.assertEqual(session.ready["count"], 6, "--total is ignored once the state file exists")
        self.assertEqual([item["id"] for item in session.page(0)],
                         ["asset-0", "asset-1", "asset-4", "asset-5", "asset-2", "asset-3"])

    def test_delete_at_removes_one_rank_and_keeps_the_others(self):
        self.start("--total", "4", "--state", self.state, "--delete-at", "1").close()
        session = self.start("--state", self.state)
        self.assertEqual([item["id"] for item in session.page(0)], ["asset-0", "asset-2", "asset-3"])
        self.assertEqual([item["rank"] for item in session.page(0)], [0, 1, 2])

    def test_inserted_ids_are_not_reused_after_a_delete(self):
        self.start("--total", "2", "--state", self.state, "--delete-at", "0").close()
        session = self.start("--state", self.state, "--insert-at", "0")
        self.assertEqual([item["id"] for item in session.page(0)], ["asset-2", "asset-1"])

    def test_out_of_range_changes_are_usage_errors(self):
        status, stderr = run_fake("--total", "2", "--delete-at", "2")
        self.assertEqual(status, 2)
        self.assertIn("--delete-at 2", stderr)
        status, stderr = run_fake("--total", "2", "--insert-at", "3")
        self.assertEqual(status, 2)
        self.assertIn("--insert-at 3", stderr)

    def test_download_from_start_rank_visits_only_that_rank_onward_and_logs_it(self):
        session = self.start("--total", "6")
        session.page(0, limit=2)
        replies = session.download(self.dest, startRank=4)
        downloaded = [r for r in replies if r.get("event") == "downloaded"]
        self.assertEqual([(r["rank"], r["asset"]) for r in downloaded], [(4, "asset-4"), (5, "asset-5")])
        self.assertEqual(replies[-1]["event"], "done")
        self.assertEqual(replies[-1]["downloaded"], 2)
        self.assertEqual(replies[0]["total"], 2)
        session.close()
        lines = self.launch_lines()
        self.assertIn("page offset=0", [line.split(" ", 1)[1] for line in lines if " page " in line])
        self.assertTrue(any(line.endswith("startRank=4 mode=allExcept layout=month")
                            and "download-start d" in line for line in lines), lines)
        self.assertTrue(any("download-ended d" in line for line in lines), lines)

    def test_downloads_report_the_rank_of_each_item(self):
        self.start("--total", "3", "--state", self.state, "--insert-at", "0").close()
        session = self.start("--state", self.state)
        replies = session.download(self.dest, startRank=0)
        ranks = [(r["asset"], r["rank"]) for r in replies if r.get("event") == "downloaded"]
        self.assertEqual(ranks, [("asset-3", 0), ("asset-0", 1), ("asset-1", 2), ("asset-2", 3)])

    def test_layout_none_puts_files_directly_in_the_destination(self):
        session = self.start("--total", "2")
        replies = session.download(self.dest, layout="none", ids=["asset-0"], mode="only")
        self.assertEqual(replies[-1]["downloaded"], 1)
        self.assertTrue(os.path.isfile(os.path.join(self.dest, "IMG_000000.JPG")))
        self.assertFalse(os.path.exists(os.path.join(self.dest, "2001")))

    def test_month_layout_paths_and_existing_files_report_as_skipped(self):
        session = self.start("--total", "2")
        month_path = os.path.join(self.dest, "2001", "01", "IMG_000001.JPG")
        os.makedirs(os.path.dirname(month_path))
        with open(month_path, "w") as handle:
            handle.write("already here")
        replies = session.download(self.dest, startRank=0)
        skipped = [r for r in replies if r.get("event") == "skipped"]
        self.assertEqual([(r["asset"], r["rank"], r["path"]) for r in skipped],
                         [("asset-1", 1, month_path)])
        self.assertEqual(replies[-1]["skipped"], 1)
        self.assertEqual(replies[-1]["downloaded"], 1)

    def test_throttle_after_ends_the_download_with_a_service_unavailable_error(self):
        session = self.start("--total", "5", "--throttle-after", "2")
        replies = session.download(self.dest)
        self.assertEqual([r["event"] for r in replies].count("downloaded"), 2)
        last = replies[-1]
        self.assertEqual(last["event"], "error")
        self.assertEqual(last["kind"], "PyiCloudServiceUnavailableException")
        self.assertIn("temporary refusing to serve icloudpd", last["message"])
        self.assertFalse(any(r["event"] == "done" for r in replies))
        self.assertTrue(os.path.isfile(os.path.join(self.dest, "2001", "01", "IMG_000001.JPG")))
        self.assertFalse(os.path.exists(os.path.join(self.dest, "2001", "01", "IMG_000002.JPG")))
        session.close()
        self.assertTrue(any("download-ended d" in line for line in self.launch_lines()))

    def test_throttle_does_not_count_skipped_items(self):
        session = self.start("--total", "3", "--throttle-after", "1")
        first = session.download(self.dest, ids=["asset-0"], mode="only")
        self.assertEqual(first[-1]["event"], "done")
        # asset-0 is already on disk, so it is skipped without counting; asset-1 is the second new item.
        replies = session.download(self.dest)
        item_events = [r["event"] for r in replies if r["event"] in ("skipped", "downloaded", "failed")]
        self.assertEqual(item_events, ["skipped"])
        self.assertEqual(replies[-1]["event"], "error")
        self.assertEqual(replies[-1]["kind"], "PyiCloudServiceUnavailableException")


if __name__ == "__main__":
    unittest.main()
