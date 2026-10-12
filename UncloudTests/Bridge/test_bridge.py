"""Unit checks for photo_bridge.py with a fake iCloud service. No network, no account.

Run with the bundled runtime:
  Vendor/icloudpd-runtime/python/bin/python3.13 -I -B test_bridge.py PATH/TO/photo_bridge.py
"""

import base64
import hashlib
import importlib.util
import io
import json
import logging
import os
import sys
import tempfile
import threading
import unittest

BRIDGE_PATH = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("photo_bridge", BRIDGE_PATH)
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)  # applies the semaphore patch before icloudpd imports

import multiprocessing  # noqa: E402

assert multiprocessing.Lock is threading.Lock, "semaphore patch not applied"

from icloudpd import base, cli  # noqa: E402
from pyicloud_ipd.services.photos import PhotoAlbum  # noqa: E402

pb.patch_icloudpd_for_bridge()

# MARK: - Fake CloudKit


def payload(asset_id: str, kind: str) -> bytes:
    return f"{asset_id}:{kind}".encode() * 7


def res(asset_id: str, kind: str):
    data = payload(asset_id, kind)
    return {
        "value": {
            "size": len(data),
            "downloadURL": f"https://fake.example/{asset_id}/{kind}",
            "fileChecksum": base64.b64encode(hashlib.sha1(data).digest()).decode(),
        }
    }


def records(asset_id, filename, item_type, ms, live=False, thumb=True, filename_type="STRING"):
    if filename_type == "ENCRYPTED_BYTES":
        name = {"type": "ENCRYPTED_BYTES", "value": base64.b64encode(filename.encode()).decode()}
    else:
        name = {"type": "STRING", "value": filename}
    master = {
        "recordName": asset_id,
        "recordType": "CPLMaster",
        "fields": {
            "filenameEnc": name,
            "itemType": {"value": item_type},
            "resOriginalRes": res(asset_id, "original"),
            "resOriginalFileType": {"value": item_type},
        },
    }
    if thumb:
        master["fields"]["resJPEGThumbRes"] = res(asset_id, "thumb")
        master["fields"]["resJPEGThumbFileType"] = {"value": "public.jpeg"}
    if live:
        master["fields"]["resOriginalVidComplRes"] = res(asset_id, "live")
        master["fields"]["resOriginalVidComplFileType"] = {"value": "com.apple.quicktime-movie"}
    asset = {
        "recordName": "A-" + asset_id,
        "recordType": "CPLAsset",
        "recordChangeTag": "x",
        "fields": {
            "masterRef": {"value": {"recordName": asset_id}},
            "assetDate": {"value": ms},
            "addedDate": {"value": ms},
        },
    }
    return master, asset


def ms(y, m, d, h=12):
    import datetime

    return int(datetime.datetime(y, m, d, h, 0, 0).astimezone().timestamp() * 1000)


SAMPLES = [
    records("ID01", "IMG_0001.HEIC", "public.heic", ms(2023, 12, 31, 23), live=True),
    records("ID02", "IMG_0002.JPG", "public.jpeg", ms(2024, 1, 5)),
    records("ID03", "MVI_0003.MOV", "com.apple.quicktime-movie", ms(2024, 1, 6)),
    # Same name as ID02 in the same month, different size: icloudpd's dedup suffix.
    records("ID04", "IMG_0002.JPG", "public.jpeg", ms(2024, 1, 7)),
    records("ID05", "Bad:Name?.PNG", "public.png", ms(2024, 2, 1), filename_type="ENCRYPTED_BYTES"),
    records("ID06", "IMG_0006.HEIC", "public.heic", ms(2024, 7, 15), live=True, thumb=False),
]
# ID04 is bigger than ID02 so the names collide with different sizes.
SAMPLES[3][0]["fields"]["resOriginalRes"]["value"]["size"] += 1


class FakeResponse:
    def __init__(self, data):
        self._data = data
        self.ok = True

    def json(self):
        return self._data

    def iter_content(self, chunk_size=1024):
        for i in range(0, len(self._data), chunk_size):
            yield self._data[i : i + chunk_size]


class FakeSession:
    def __init__(self, samples):
        self.by_url = {}
        self.downloads = []
        for master, _ in samples:
            for key, value in master["fields"].items():
                if key.endswith("Res"):
                    url = value["value"]["downloadURL"]
                    asset_id, kind = url.rsplit("/", 2)[-2:]
                    data = payload(asset_id, kind)
                    if master["recordName"] == "ID04" and kind == "original":
                        data += b"!"
                    self.by_url[url] = data
        self.requests = 0

    def get(self, url, headers=None, stream=False):
        self.downloads.append(url)
        start = int((headers or {}).get("Range", "bytes=0-")[6:-1] or 0)
        return FakeResponse(self.by_url[url][start:])


class FakeAlbum(PhotoAlbum):
    """A PhotoAlbum whose CloudKit query is answered from memory; paging is icloudpd's own."""

    def __init__(self, samples, session, name=""):
        super().__init__({}, session, "https://fake", name, "list", "obj")
        self.samples = samples

    def photos_request(self):
        self.session.requests += 1
        chunk = self.samples[self.offset : self.offset + self.page_size]
        recs = []
        for master, asset in chunk:
            recs += [asset, master]
        return FakeResponse({"records": recs})

    def __len__(self):
        return len(self.samples)


class FakeLibrary:
    def __init__(self, samples, session):
        self._samples = samples
        self.session = session
        self.private_libraries = {"PrimarySync": self}
        self.shared_libraries = {}
        self.album_members = {"Trip": [samples[1], samples[5]]}

    @property
    def all(self):
        return FakeAlbum(self._samples, self.session)

    @property
    def albums(self):
        result = {"Favorites": FakeAlbum([], self.session, "Favorites")}
        for name, members in self.album_members.items():
            result[name] = FakeAlbum(members, self.session, name)
        return result


class FakeICloud:
    def __init__(self, library):
        self.photos = library


class Collector(pb.Channel):
    def __init__(self):
        super().__init__(io.StringIO())
        self.messages = []

    def send(self, message):
        json.dumps(message)
        self.messages.append(message)


def make_bridge(samples=SAMPLES):
    session = FakeSession(samples)
    library = FakeLibrary(samples, session)
    channel = Collector()
    bridge = pb.Bridge(channel, FakeICloud(library), library, "user@example.com", "/nonexistent-cookies")
    return bridge, channel, session


def tree(root):
    result = {}
    for folder, _, files in os.walk(root):
        for name in files:
            path = os.path.join(folder, name)
            with open(path, "rb") as f:
                result[os.path.relpath(path, root)] = f.read()
    return result


def run_icloudpd(samples, directory, layout="month", album=None, xmp=False):
    """Runs icloudpd's real entry point (run_with_configs) with the engine's arguments and a fake service."""
    args = pb.icloudpd_arguments("user@example.com", "/nonexistent-cookies", directory, layout, xmp)
    if album:
        args += ["-a", album]
    global_config, user_configs = cli.parse(args)
    session = FakeSession(samples)
    library = FakeLibrary(samples, session)
    original = base.authenticator
    base.authenticator = lambda *a, **k: FakeICloud(library)
    stream = io.StringIO()
    handler = logging.StreamHandler(stream)
    logging.getLogger("icloudpd").addHandler(handler)
    try:
        assert base.run_with_configs(global_config, user_configs) == 0
    finally:
        base.authenticator = original
        logging.getLogger("icloudpd").removeHandler(handler)
    return session, stream.getvalue()


# MARK: - Tests


class ChannelTests(unittest.TestCase):
    def test_routes_passwords_cancels_and_requests(self):
        out = io.StringIO()
        channel = pb.Channel(out)
        channel.feed('{"password":"s3cret"}\n')
        channel.feed('{"cmd":"cancel","target":7}\n')
        channel.feed('{"id":1,"cmd":"page","offset":0,"limit":2}\n')
        channel.feed("not json s3cret\n")
        self.assertEqual(channel._passwords.get_nowait(), "s3cret")
        self.assertTrue(channel.is_cancelled(7))
        self.assertEqual(channel.poll_request()["cmd"], "page")
        self.assertIsNone(channel.poll_request())
        self.assertNotIn("s3cret", out.getvalue())
        channel.close()
        self.assertIsNone(channel.next_request())
        self.assertTrue(channel.is_cancelled(1))


class PagingTests(unittest.TestCase):
    def test_pages_by_offset_in_icloudpd_order(self):
        bridge, channel, session = make_bridge()
        bridge.handle({"id": 1, "cmd": "page", "offset": 2, "limit": 3}, downloading=False)
        reply = channel.messages[-1]
        self.assertEqual(reply["event"], "page")
        self.assertEqual(reply["id"], 1)
        self.assertEqual([i["id"] for i in reply["items"]], ["ID03", "ID04", "ID05"])
        movie = reply["items"][0]
        self.assertEqual(movie["type"], "movie")
        self.assertEqual(movie["filename"], "MVI_0003.MOV")
        self.assertTrue(movie["created"].endswith("Z"))
        self.assertEqual(movie["thumbURL"], "https://fake.example/ID03/thumb")
        self.assertEqual(reply["items"][2]["filename"], "Bad_Name_.PNG")

    def test_page_limits_and_past_end(self):
        bridge, channel, session = make_bridge()
        bridge.handle({"id": 2, "cmd": "page", "offset": 4, "limit": 50}, downloading=False)
        self.assertEqual([i["id"] for i in channel.messages[-1]["items"]], ["ID05", "ID06"])
        self.assertIsNone(channel.messages[-1]["items"][1]["thumbURL"])
        bridge.handle({"id": 3, "cmd": "page", "offset": 99, "limit": 10}, downloading=False)
        self.assertEqual(channel.messages[-1]["items"], [])

    def test_large_page_uses_icloudpd_chunks(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(450)]
        bridge, channel, session = make_bridge(samples)
        bridge.handle({"id": 4, "cmd": "page", "offset": 120, "limit": 200}, downloading=False)
        items = channel.messages[-1]["items"]
        self.assertEqual(len(items), 200)
        self.assertEqual(items[0]["id"], "N0120")
        self.assertEqual(items[-1]["id"], "N0319")
        self.assertEqual(session.requests, 2)  # two requests of 100

    def test_count_albums_and_errors(self):
        bridge, channel, _ = make_bridge()
        bridge.handle({"id": 5, "cmd": "count"}, downloading=False)
        self.assertEqual(channel.messages[-1], {"id": 5, "event": "count", "count": 6})
        bridge.handle({"id": 6, "cmd": "albums"}, downloading=False)
        self.assertEqual(channel.messages[-1]["albums"], ["Trip"])
        bridge.handle({"id": 7, "cmd": "nope"}, downloading=False)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        bridge.handle({"id": 8, "cmd": "download", "mode": "only", "ids": [], "dest": "/tmp/x", "layout": "album", "album": "Nope"}, downloading=False)
        self.assertEqual(channel.messages[-1]["kind"], "albumNotFound")


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def download(self, bridge, **request):
        request = {"id": 9, "cmd": "download", "dest": self.root, "layout": "month", "xmp": False, **request}
        bridge.handle(request, downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == 9]

    def test_month_paths_match_icloudpd(self):
        expected_dir = os.path.join(self.root, "icloudpd")
        bridge_dir = os.path.join(self.root, "bridge")
        run_icloudpd(SAMPLES, expected_dir)
        expected = tree(expected_dir)
        # Spot-check icloudpd's naming so the comparison means something.
        for path in [
            "2023/12/IMG_0001.HEIC", "2023/12/IMG_0001.MOV", "2024/01/IMG_0002.JPG",
            "2024/01/MVI_0003.MOV", "2024/02/Bad_Name_.PNG", "2024/07/IMG_0006.MOV",
        ]:
            self.assertIn(path, expected)
        self.assertTrue(any(p.startswith("2024/01/IMG_0002-") for p in expected), expected.keys())

        bridge, channel, _ = make_bridge()
        events = self.download(bridge, mode="allExcept", ids=[], dest=bridge_dir)
        self.assertEqual(tree(bridge_dir), expected)
        kinds = [e["event"] for e in events]
        self.assertEqual(kinds.count("downloaded"), 6)
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["downloaded"], 6)
        live = next(e for e in events if e.get("asset") == "ID01")
        self.assertEqual(sorted(os.path.relpath(p, bridge_dir) for p in live["paths"]),
                         ["2023/12/IMG_0001.HEIC", "2023/12/IMG_0001.MOV"])
        progress = [e for e in events if e["event"] == "progress"]
        self.assertEqual((progress[0]["done"], progress[0]["total"]), (0, 6))
        self.assertEqual((progress[-1]["done"], progress[-1]["total"]), (6, 6))

        # A full icloudpd run over the bridge's files finds everything already there.
        session, log = run_icloudpd(SAMPLES, bridge_dir)
        self.assertEqual(session.downloads, [], log)
        self.assertEqual(tree(bridge_dir), expected)

    def test_only_mode_with_and_without_hints(self):
        bridge, channel, session = make_bridge()
        events = self.download(bridge, mode="only", ids=["ID02", "ID06", "GONE"], hints={"ID02": 1, "ID06": 5})
        done = [e for e in events if e["event"] in ("downloaded", "skipped", "failed")]
        self.assertEqual(sorted(e["asset"] for e in done), ["ID02", "ID06"])
        self.assertEqual(sorted(tree(self.root)), ["2024/01/IMG_0002.JPG", "2024/07/IMG_0006.HEIC", "2024/07/IMG_0006.MOV"])
        progress = [e for e in events if e["event"] == "progress"]
        self.assertEqual(progress[0]["total"], 3)
        self.assertEqual(progress[-1]["total"], 2)  # GONE no longer counts
        self.assertEqual(progress[-1]["done"], 2)

        # Again: everything is skipped as already there, and a wrong hint still finds the item.
        bridge, channel, session = make_bridge()
        events = self.download(bridge, mode="only", ids=["ID02", "ID06"], hints={"ID02": 4, "ID06": 0})
        self.assertEqual(sorted(e["asset"] for e in events if e["event"] == "skipped"), ["ID02", "ID06"])
        self.assertEqual(session.downloads, [])

    def test_all_except_excludes_ids(self):
        bridge, channel, session = make_bridge()
        events = self.download(bridge, mode="allExcept", ids=["ID01", "ID03", "ID04"])
        self.assertEqual(sorted(e["asset"] for e in events if e["event"] == "downloaded"), ["ID02", "ID05", "ID06"])
        self.assertEqual(events[-2]["total"], 3)
        self.assertNotIn("2023/12/IMG_0001.HEIC", tree(self.root))

    def test_album_layout_matches_icloudpd_and_xmp(self):
        expected_dir = os.path.join(self.root, "icloudpd")
        bridge_dir = os.path.join(self.root, "bridge")
        run_icloudpd(SAMPLES, expected_dir, layout="album", album="Trip", xmp=True)
        bridge, channel, _ = make_bridge()
        events = self.download(bridge, mode="only", ids=["ID06", "ID02", "ID03"], layout="album", album="Trip", dest=bridge_dir, xmp=True)
        self.assertEqual(sorted(tree(bridge_dir)), sorted(tree(expected_dir)))
        self.assertIn("IMG_0006.HEIC.xmp", tree(bridge_dir))
        self.assertEqual(sorted(e["asset"] for e in events if e["event"] == "downloaded"), ["ID02", "ID06"])
        self.assertEqual(events[-2]["total"], 2)

    def test_cancel_stops_between_items_and_browsing_is_answered(self):
        bridge, channel, session = make_bridge()
        channel.feed('{"id":20,"cmd":"page","offset":0,"limit":1}')
        channel.feed('{"id":21,"cmd":"download","mode":"only","ids":[],"dest":"/tmp/never"}')
        original = bridge.capture.reset
        calls = {"n": 0}

        def cancel_after_first():
            calls["n"] += 1
            if calls["n"] == 2:  # as the first item finishes
                channel.feed('{"cmd":"cancel","target":9}')
            original()

        bridge.capture.reset = cancel_after_first
        events = self.download(bridge, mode="allExcept", ids=[])
        self.assertEqual(events[-1]["event"], "done")
        self.assertTrue(events[-1]["cancelled"])
        self.assertEqual(events[-1]["downloaded"], 1)
        page = next(m for m in channel.messages if m.get("id") == 20)
        self.assertEqual(page["event"], "page")
        self.assertEqual(len(bridge._deferred), 1)  # the second download waits its turn

    def big_download(self, bridge, session, on_chunk, chunks=40):
        """Makes ID02's original `chunks` download chunks long and calls `on_chunk(n)` as each is read."""
        url = "https://fake.example/ID02/original"
        session.by_url[url] = bytes(range(256)) * (chunks * pb.DOWNLOAD_CHUNK // 256)
        original_get = session.get
        read = {"n": 0}

        def get(url, headers=None, stream=False):
            response = original_get(url, headers=headers, stream=stream)
            inner = response.iter_content

            def iter_content(chunk_size=1024):
                for chunk in inner(chunk_size):
                    read["n"] += 1
                    on_chunk(read["n"])
                    yield chunk

            response.iter_content = iter_content
            return response

        session.get = get
        return url, read

    def test_cancel_stops_inside_a_file_and_removes_the_partial(self):
        bridge, channel, session = make_bridge()

        def on_chunk(n):
            if n == 3:
                channel.feed('{"cmd":"cancel","target":9}')

        url, read = self.big_download(bridge, session, on_chunk)
        events = self.download(bridge, mode="only", ids=["ID02", "ID03"])
        self.assertEqual(events[-1]["event"], "done")
        self.assertTrue(events[-1]["cancelled"])
        self.assertEqual(events[-1]["downloaded"], 0)
        self.assertEqual(events[-1]["failed"], 0)
        self.assertNotIn("downloaded", [e["event"] for e in events])
        # Stopped after the chunk that saw the cancel, not at the end of the file or the next item.
        self.assertLessEqual(read["n"], 4)
        self.assertEqual(tree(self.root), {})
        self.assertEqual(session.downloads, [url])

    def test_pause_holds_inside_a_file_answers_browsing_and_resumes(self):
        bridge, channel, session = make_bridge()
        resumed = threading.Event()

        def resume_after_page():
            for _ in range(500):
                if any(m.get("id") == 50 for m in channel.messages):
                    break
                threading.Event().wait(0.01)
            # The download held while the page was answered.
            resumed.read_while_paused = read["n"]
            channel.feed('{"cmd":"resume","target":9}')
            resumed.set()

        def on_chunk(n):
            if n == 5:
                channel.feed('{"cmd":"pause","target":9}')
                channel.feed('{"id":50,"cmd":"page","offset":0,"limit":2}')
                channel.feed('{"id":51,"cmd":"ping"}')
                threading.Thread(target=resume_after_page, daemon=True).start()

        url, read = self.big_download(bridge, session, on_chunk)
        events = self.download(bridge, mode="only", ids=["ID02"])
        self.assertTrue(resumed.is_set())
        self.assertEqual(resumed.read_while_paused, 5)
        self.assertEqual(events[-1]["event"], "done")
        self.assertFalse(events[-1]["cancelled"])
        self.assertEqual(events[-1]["downloaded"], 1)
        page = next(m for m in channel.messages if m.get("id") == 50)
        self.assertEqual(len(page["items"]), 2)
        self.assertIn({"id": 51, "event": "pong"}, channel.messages)
        # The rest was asked for again from where the file stopped, and the file is whole.
        self.assertEqual(session.downloads, [url, url])
        self.assertEqual(tree(self.root), {"2024/01/IMG_0002.JPG": session.by_url[url]})

    def test_resume_after_pause_starts_over_when_the_server_ignores_the_range(self):
        bridge, channel, session = make_bridge()

        def get(url, headers=None, stream=False):
            response = first_get(url, headers=headers, stream=stream)
            if headers and headers.get("Range", "bytes=0-") != "bytes=0-":
                # A server that ignores Range answers 200 with the whole file.
                response = FakeResponse(session.by_url[url])
                response.status_code = 200
            return response

        def resume_after_page():
            for _ in range(500):
                if any(m.get("id") == 50 for m in channel.messages):
                    break
                threading.Event().wait(0.01)
            channel.feed('{"cmd":"resume","target":9}')

        def on_chunk(n):
            if n == 5:
                channel.feed('{"cmd":"pause","target":9}')
                channel.feed('{"id":50,"cmd":"page","offset":0,"limit":2}')
                threading.Thread(target=resume_after_page, daemon=True).start()

        url, _ = self.big_download(bridge, session, on_chunk)
        first_get = session.get
        session.get = get
        events = self.download(bridge, mode="only", ids=["ID02"])
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["downloaded"], 1)
        self.assertEqual(len(session.downloads), 2)
        # The whole file, not the part before the pause followed by the whole file again.
        self.assertEqual(tree(self.root), {"2024/01/IMG_0002.JPG": session.by_url[url]})

    def test_pause_on_the_last_chunk_finishes_the_file_without_asking_again(self):
        bridge, channel, session = make_bridge()

        def resume_after_page():
            for _ in range(500):
                if any(m.get("id") == 50 for m in channel.messages):
                    break
                threading.Event().wait(0.01)
            channel.feed('{"cmd":"resume","target":9}')

        def on_chunk(n):
            if n == 40:
                channel.feed('{"cmd":"pause","target":9}')
                channel.feed('{"id":50,"cmd":"page","offset":0,"limit":2}')
                threading.Thread(target=resume_after_page, daemon=True).start()

        url, _ = self.big_download(bridge, session, on_chunk)
        first_get = session.get
        data = session.by_url[url]

        def get(url, headers=None, stream=False):
            start = int((headers or {}).get("Range", "bytes=0-")[6:-1] or 0)
            if start >= len(data):
                # Asking for bytes past the end gets 416, as iCloud answers it.
                response = FakeResponse(b"")
                response.ok = False
                response.status_code = 416
                return response
            response = first_get(url, headers=headers, stream=stream)
            response.headers = {"Content-Length": str(len(data) - start)}
            return response

        session.get = get
        events = self.download(bridge, mode="only", ids=["ID02"])
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["downloaded"], 1)
        self.assertEqual(events[-1]["failed"], 0)
        self.assertEqual(len(session.downloads), 1)
        self.assertEqual(tree(self.root), {"2024/01/IMG_0002.JPG": data})

    def test_pause_holds_between_items_and_cancel_ends_the_hold(self):
        bridge, channel, session = make_bridge()
        channel.feed('{"cmd":"pause","target":9}')
        channel.feed('{"id":52,"cmd":"count"}')

        def cancel_after_count():
            for _ in range(500):
                if any(m.get("id") == 52 for m in channel.messages):
                    break
                threading.Event().wait(0.01)
            channel.feed('{"cmd":"cancel","target":9}')

        threading.Thread(target=cancel_after_count, daemon=True).start()
        events = self.download(bridge, mode="allExcept", ids=[])
        self.assertTrue(events[-1]["cancelled"])
        self.assertEqual(events[-1]["downloaded"], 0)
        self.assertEqual(session.downloads, [])
        self.assertEqual(next(m for m in channel.messages if m.get("id") == 52)["count"], 6)
        # A finished request's pause and cancel are forgotten.
        self.assertFalse(channel.is_paused(9))
        self.assertFalse(channel.is_cancelled(9))

    def test_ping_is_answered_when_idle_and_between_items(self):
        bridge, channel, session = make_bridge()
        channel.feed('{"id":60,"cmd":"ping"}')
        bridge.handle(channel.poll_request(), downloading=False)
        self.assertEqual(channel.messages, [{"id": 60, "event": "pong"}])
        channel.feed('{"id":61,"cmd":"ping"}')
        self.download(bridge, mode="only", ids=["ID02"])
        self.assertEqual(channel.messages.count({"id": 61, "event": "pong"}), 1)

    def test_failure_is_reported_per_item(self):
        bridge, channel, session = make_bridge()
        def broken(url, headers=None, stream=False):
            response = FakeResponse(b"")
            response.ok = False
            return response
        session.get = broken
        events = self.download(bridge, mode="only", ids=["ID02"])
        failed = [e for e in events if e["event"] == "failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]["asset"], "ID02")
        self.assertIn("Could not find URL", failed[0]["reason"])


class StatsTests(unittest.TestCase):
    @staticmethod
    def expected_bytes(samples):
        sizes = {}
        for master, _ in samples:
            fields = master["fields"]
            size = fields["resOriginalRes"]["value"]["size"]
            if "resOriginalVidComplRes" in fields:
                size += fields["resOriginalVidComplRes"]["value"]["size"]
            sizes[master["recordName"]] = size
        return sizes

    def stats(self, bridge, **request):
        bridge.handle({"id": 30, "cmd": "stats", **request}, downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == 30]

    def test_sizes_include_live_photo_movies(self):
        bridge, channel, session = make_bridge()
        events = self.stats(bridge)
        expected = self.expected_bytes(SAMPLES)
        progress = [e for e in events if e["event"] == "statsProgress"]
        sizes = {}
        for event in progress:
            sizes.update(event["sizes"])
            self.assertEqual(event["unsized"], [])
        self.assertEqual(sizes, expected)
        # The Live Photos count their movie too.
        self.assertGreater(sizes["ID01"], SAMPLES[0][0]["fields"]["resOriginalRes"]["value"]["size"])
        final = events[-1]
        self.assertEqual(final["event"], "stats")
        self.assertEqual((final["done"], final["total"]), (6, 6))
        self.assertEqual(final["bytes"], sum(expected.values()))
        self.assertTrue(final["complete"])
        self.assertFalse(final["cancelled"])
        self.assertEqual(session.downloads, [])

    def test_bytes_match_what_icloudpd_writes(self):
        with tempfile.TemporaryDirectory() as root:
            run_icloudpd(SAMPLES, root)
            written = sum(len(data) for data in tree(root).values())
        bridge, channel, session = make_bridge()
        self.assertEqual(self.stats(bridge)[-1]["bytes"], written)

    def test_page_items_carry_download_bytes(self):
        bridge, channel, session = make_bridge()
        bridge.handle({"id": 31, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        items = channel.messages[-1]["items"]
        expected = self.expected_bytes(SAMPLES)
        self.assertEqual({i["id"]: i["bytes"] for i in items}, expected)
        self.assertEqual(items[2]["bytes"], items[2]["size"])  # a movie has no Live Photo part

    def test_walks_pages_from_an_offset(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(250)]
        bridge, channel, session = make_bridge(samples)
        events = self.stats(bridge, offset=40)
        progress = [e for e in events if e["event"] == "statsProgress"]
        self.assertEqual([e["done"] for e in progress], [100, 200, 210])
        self.assertEqual([len(e["sizes"]) for e in progress], [100, 100, 10])
        self.assertIn("N0040", progress[0]["sizes"])
        self.assertNotIn("N0039", progress[0]["sizes"])
        self.assertEqual(events[-1]["total"], 250)
        self.assertTrue(events[-1]["complete"])
        self.assertEqual(events[-1]["bytes"], sum(self.expected_bytes(samples[40:]).values()))

    def test_cancel_stops_after_the_page(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(350)]
        bridge, channel, session = make_bridge(samples)
        original = channel.send

        def send(message):
            original(message)
            if message.get("event") == "statsProgress":
                channel.feed('{"cmd":"cancel","target":30}')

        channel.send = send
        events = self.stats(bridge)
        self.assertEqual(events[-1]["event"], "stats")
        self.assertEqual(events[-1]["done"], 100)
        self.assertFalse(events[-1]["complete"])
        self.assertTrue(events[-1]["cancelled"])
        self.assertEqual(session.requests, 1)

    def test_answers_browsing_and_yields_to_a_download(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(350)]
        bridge, channel, session = make_bridge(samples)
        channel.feed('{"id":40,"cmd":"page","offset":0,"limit":1}')
        events = self.stats(bridge)
        page = next(m for m in channel.messages if m.get("id") == 40)
        self.assertEqual(page["event"], "page")
        self.assertTrue(events[-1]["complete"])

        bridge, channel, session = make_bridge(samples)
        channel.feed('{"id":41,"cmd":"download","mode":"only","ids":[],"dest":"/tmp/never"}')
        events = self.stats(bridge)
        self.assertEqual(events[-1]["done"], 100)
        self.assertFalse(events[-1]["complete"])
        self.assertFalse(events[-1]["cancelled"])
        self.assertEqual(len(bridge._deferred), 1)

    def test_a_stats_request_during_a_download_waits(self):
        bridge, channel, session = make_bridge()
        bridge.handle({"id": 32, "cmd": "stats"}, downloading=True)
        self.assertEqual(len(bridge._deferred), 1)
        self.assertEqual([m for m in channel.messages if m.get("id") == 32], [])


class HintTests(unittest.TestCase):
    def test_windows(self):
        self.assertEqual(pb.hint_windows([5, 1, 3, 200, 210, 1000]), [range(1, 6), range(200, 211), range(1000, 1001)])
        self.assertEqual(len(pb.hint_windows(range(0, 250))), 3)


class SignInTests(unittest.TestCase):
    def test_two_factor_and_missing_password_need_sign_in(self):
        import icloudpd.authentication as auth

        channel = Collector()
        captured = {}

        def fake_authenticator(logger, domain, providers, mfa, status, username, notificator, observer, cookie_directory, client_id):
            captured.update(domain=domain, username=username, cookie_directory=cookie_directory, client_id=client_id)
            reader, _ = providers["console"]
            reader(username)
            notificator()

        original = auth.authenticator
        auth.authenticator = fake_authenticator
        try:
            channel._passwords.put("pw")
            os.environ["CLIENT_ID"] = "client-x"
            with self.assertRaises(pb.NeedsSignIn):
                pb.authenticate(channel, "user@example.com", "/cookies")
            self.assertEqual(captured, {"domain": "com", "username": "user@example.com", "cookie_directory": "/cookies", "client_id": "client-x"})
            self.assertEqual(channel.messages, [{"event": "needPassword"}])
            channel._passwords.put("")
            with self.assertRaises(pb.NeedsSignIn):
                pb.authenticate(channel, "user@example.com", "/cookies")
        finally:
            auth.authenticator = original
            os.environ.pop("CLIENT_ID", None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
