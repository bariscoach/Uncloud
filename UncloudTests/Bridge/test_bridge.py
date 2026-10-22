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
import time
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

    @property
    def content(self):
        return json.dumps(self._data).encode()

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
        self.bodies = []

    def get(self, url, headers=None, stream=False):
        self.downloads.append(url)
        start = int((headers or {}).get("Range", "bytes=0-")[6:-1] or 0)
        return FakeResponse(self.by_url[url][start:])


def only_fields(record, wanted):
    return {**record, "fields": {k: v for k, v in record["fields"].items() if k in wanted}}


class AlbumRoute:
    """The session an album's record queries go through: the real PhotoAlbum builds each query (its startRank,
    resultsLimit and desiredKeys), and this answers it from `samples` with only the fields asked for, as CloudKit
    does. `delay` seconds pass per query; `before_query`, when set, is called before each query is answered."""

    def __init__(self, session, samples, delay=0.0):
        self._session = session
        self._samples = samples
        self._delay = delay
        self.before_query = None

    def post(self, url, data=None, headers=None):
        body = json.loads(data)
        self._session.requests += 1
        self._session.bodies.append(body)
        if self.before_query is not None:
            self.before_query()
        if self._delay:
            time.sleep(self._delay)
        offset = next(f["fieldValue"]["value"] for f in body["query"]["filterBy"] if f["fieldName"] == "startRank")
        limit = body["resultsLimit"] // 2
        wanted = set(body["desiredKeys"])
        recs = []
        for master, asset in self._samples[offset : offset + limit]:
            recs += [only_fields(asset, wanted), only_fields(master, wanted)]
        return FakeResponse({"records": recs})

    def __getattr__(self, name):
        return getattr(self._session, name)


class FakeAlbum(PhotoAlbum):
    """A PhotoAlbum whose CloudKit queries are answered from memory; paging and query building are icloudpd's own."""

    def __init__(self, samples, session, name="", delay=0.0):
        super().__init__({}, AlbumRoute(session, samples, delay), "https://fake", name, "list", "obj")
        self.samples = samples

    def __len__(self):
        return len(self.samples)


class FakeLibrary:
    def __init__(self, samples, session, trash=None):
        self._samples = samples
        self._trash = [] if trash is None else trash
        self.session = session
        self.before_query = None
        self.service_endpoint = "https://fake"
        self.params = {"clientId": "fake"}
        self.zone_id = {"zoneName": "PrimarySync"}
        self.private_libraries = {"PrimarySync": self}
        self.shared_libraries = {}
        self.album_members = {"Trip": [samples[1], samples[5]]}

    @property
    def all(self):
        album = FakeAlbum(self._samples, self.session)
        album.session.before_query = self.before_query
        return album

    @property
    def recently_deleted(self):
        return FakeAlbum(self._trash, self.session, "Recently Deleted")

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
        self.assertTrue(movie["added"].endswith("Z"))
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


class SessionsProtocolTests(unittest.TestCase):
    """startRank, ranks, the flat layout, full paths and the run-ending throttle (sessions plan, C1)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def download(self, bridge, request_id=9, **request):
        request = {"id": request_id, "cmd": "download", "dest": self.root, "layout": "month", "xmp": False, **request}
        bridge.handle(request, downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == request_id]

    @staticmethod
    def many(count):
        return [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(count)]

    def test_page_items_carry_their_rank(self):
        bridge, channel, _ = make_bridge()
        bridge.handle({"id": 1, "cmd": "page", "offset": 2, "limit": 3}, downloading=False)
        self.assertEqual([(i["id"], i["rank"]) for i in channel.messages[-1]["items"]],
                         [("ID03", 2), ("ID04", 3), ("ID05", 4)])

    def test_a_walk_over_known_items_reports_its_rank(self):
        """A long run of items passed over (already on the drive) sends "walked" events with the rank the walk
        is at, so the app can show progress without a file check per item."""
        samples = self.many(250)
        bridge, channel, session = make_bridge(samples)
        known = [f"N{i:04d}" for i in range(200)]
        events = self.download(bridge, mode="allExcept", ids=known)
        walked = [e["rank"] for e in events if e["event"] == "walked"]
        self.assertEqual(walked, [pb.PAGE_CHUNK - 1, 2 * pb.PAGE_CHUNK - 1])
        self.assertTrue(all(e["id"] == 9 for e in events if e["event"] == "walked"))
        self.assertEqual([e["asset"] for e in events if e["event"] == "downloaded"],
                         [f"N{i:04d}" for i in range(200, 250)])
        self.assertEqual(events[-1]["event"], "done")

    def test_only_mode_and_normal_walks_send_no_walked_events(self):
        samples = self.many(250)
        bridge, channel, session = make_bridge(samples)
        events = self.download(bridge, mode="allExcept", ids=[])
        self.assertEqual([e for e in events if e["event"] == "walked"], [])

    def test_start_rank_pages_from_that_rank_only(self):
        samples = self.many(250)
        bridge, channel, session = make_bridge(samples)
        offsets = []
        original = FakeAlbum.photos_request

        def photos_request(album):
            offsets.append(album.offset)
            return original(album)

        FakeAlbum.photos_request = photos_request
        try:
            events = self.download(bridge, mode="allExcept", ids=["N0141"], startRank=140)
        finally:
            FakeAlbum.photos_request = original
        # Queries for ranks 140-239 and 235-249 (each page after the first starts a few items early, to notice
        # removals), and icloudpd's empty one that ends its walk; none before 140.
        self.assertEqual(offsets, [140, 140 + pb.PAGE_CHUNK - pb.WALK_OVERLAP, 250])
        done = [e for e in events if e["event"] in ("downloaded", "skipped", "failed")]
        self.assertEqual(done[0]["asset"], "N0140")
        self.assertEqual(len(done), 109)
        self.assertTrue(all(e["rank"] == int(e["asset"][1:]) for e in done))
        self.assertNotIn("N0141", [e["asset"] for e in done])
        progress = [e for e in events if e["event"] == "progress"]
        self.assertEqual(progress[0]["total"], 110)
        self.assertEqual((progress[-1]["done"], progress[-1]["total"]), (109, 109))
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["downloaded"], 109)
        self.assertEqual(len(tree(self.root)), 109)

    def walk_while_changing(self, count, change):
        """Downloads everything (allExcept, no IDs) while `change(samples, query_number)` edits the library
        before each CloudKit query is answered. Returns the assets visited, in order."""
        samples = self.many(count)
        bridge, channel, session = make_bridge(samples)
        original = FakeAlbum.photos_request
        queries = []

        def photos_request(album):
            queries.append(album.offset)
            change(samples, len(queries))
            return original(album)

        FakeAlbum.photos_request = photos_request
        try:
            events = self.download(bridge, mode="allExcept", ids=[])
        finally:
            FakeAlbum.photos_request = original
        self.assertEqual(events[-1]["event"], "done")
        return [e["asset"] for e in events if e["event"] in ("downloaded", "skipped", "failed")], samples

    def test_a_removal_above_the_walk_does_not_skip_the_item_at_the_page_boundary(self):
        # QC defect 3: after the first page (ranks 0-99) is visited, rank 10 is deleted, so the item that was at
        # rank 100 moves up to 99. A plain offset walk asks for rank 100 next and never sees it.
        def change(samples, query):
            if query == 2:
                del samples[10]

        visited, samples = self.walk_while_changing(250, change)
        self.assertIn("N0100", visited)
        self.assertEqual(len(visited), len(set(visited)))
        self.assertEqual(set(visited) - {"N0010"}, {master["recordName"] for master, _ in samples})

    def test_more_removals_than_the_overlap_and_an_addition_are_handled_too(self):
        def change(samples, query):
            if query == 2:
                del samples[5:5 + 3 * pb.WALK_OVERLAP]
            if query == 4:
                samples.insert(0, records("NEW", "IMG_NEW.JPG", "public.jpeg", ms(2021, 1, 1)))

        visited, samples = self.walk_while_changing(300, change)
        removed = {f"N{i:04d}" for i in range(5, 5 + 3 * pb.WALK_OVERLAP)}
        expected = {master["recordName"] for master, _ in samples} - {"NEW"}
        # Every item still there is visited once; the ones removed after being visited were visited before.
        self.assertEqual(set(visited) - removed, expected)
        self.assertEqual(len(visited), len(set(visited)))

    def test_stop_at_ends_an_all_except_walk_before_that_asset(self):
        bridge, channel, session = make_bridge(self.many(30))
        events = self.download(bridge, mode="allExcept", ids=["N0001"], stopAt="N0004")
        done = [e["asset"] for e in events if e["event"] in ("downloaded", "skipped", "failed")]
        self.assertEqual(done, ["N0000", "N0002", "N0003"])
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual((events[-2]["done"], events[-2]["total"]), (3, 3))
        bridge, channel, session = make_bridge(self.many(6))
        bridge.handle({"id": 5, "cmd": "download", "dest": self.root, "mode": "only", "ids": ["N0000"],
                       "stopAt": "N0001"}, downloading=False)
        self.assertEqual(channel.messages[-1]["event"], "error")
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")

    def test_a_file_that_appears_while_downloading_is_never_overwritten(self):
        # QC defect 5: icloudpd chose the name when nothing was there; a file appears before the finished
        # download is moved into place. It must be left alone, and the item fails (the next run names it again).
        samples = self.many(6)
        bridge, channel, session = make_bridge(samples)
        target = os.path.join(self.root, "2020", "01", "IMG_0000.JPG")
        original_get = FakeSession.get

        def get(fake, url, headers=None, stream=False):
            response = original_get(fake, url, headers, stream)
            if "N0000" in url:
                inner = response.iter_content

                def iter_content(chunk_size=1024):
                    for chunk in inner(chunk_size):
                        yield chunk
                    with open(target, "w") as handle:
                        handle.write("the user's own file")

                response.iter_content = iter_content
            return response

        FakeSession.get = get
        try:
            events = self.download(bridge, mode="allExcept", ids=[])
        finally:
            FakeSession.get = original_get
        with open(target) as handle:
            self.assertEqual(handle.read(), "the user's own file")
        failed = [e for e in events if e["event"] == "failed"]
        self.assertEqual([e["asset"] for e in failed], ["N0000"])
        self.assertIn("FileAppeared", failed[0]["reason"])
        self.assertEqual([e["asset"] for e in events if e["event"] == "downloaded"], [f"N000{i}" for i in range(1, 6)])
        self.assertFalse([name for name in os.listdir(os.path.dirname(target)) if name.endswith(".part")])

    def test_move_into_place_never_replaces_a_file(self):
        temp = os.path.join(self.root, "x.part")
        path = os.path.join(self.root, "x.JPG")
        for content, name in (("download", temp), ("mine", path)):
            with open(name, "w") as handle:
                handle.write(content)
        self.assertFalse(pb.move_into_place(temp, path))
        with open(path) as handle:
            self.assertEqual(handle.read(), "mine")
        os.remove(path)
        self.assertTrue(pb.move_into_place(temp, path))
        self.assertFalse(os.path.exists(temp))
        with open(path) as handle:
            self.assertEqual(handle.read(), "download")

    def test_move_without_hard_links_still_never_replaces_a_file(self):
        # A file system without renamex_np or hard links (FAT32, some shares) takes the copy path.
        import errno as errno_module
        from unittest import mock

        temp = os.path.join(self.root, "y.part")
        path = os.path.join(self.root, "y.JPG")
        with open(temp, "w") as handle:
            handle.write("download")
        with mock.patch.object(pb, "_renamex_excl", return_value=None), \
                mock.patch.object(pb.os, "link", side_effect=OSError(errno_module.EPERM, "no links")):
            with open(path, "w") as handle:
                handle.write("mine")
            self.assertFalse(pb.move_into_place(temp, path))
            with open(path) as handle:
                self.assertEqual(handle.read(), "mine")
            self.assertTrue(os.path.exists(temp))
            os.remove(path)
            self.assertTrue(pb.move_into_place(temp, path))
        self.assertFalse(os.path.exists(temp))
        with open(path) as handle:
            self.assertEqual(handle.read(), "download")

    def test_start_rank_in_only_mode_skips_lower_ranks_and_their_hints(self):
        samples = self.many(30)
        bridge, channel, session = make_bridge(samples)
        events = self.download(bridge, mode="only", ids=["N0003", "N0020"], hints={"N0003": 3, "N0020": 20},
                               startRank=10)
        done = [e for e in events if e["event"] == "downloaded"]
        self.assertEqual([(e["asset"], e["rank"]) for e in done], [("N0020", 20)])
        self.assertEqual(events[-2]["total"], 1)  # N0003 lies below startRank, so it no longer counts

    def test_bad_start_rank_is_refused(self):
        bridge, channel, _ = make_bridge()
        for value in (-1, "5", True):
            events = self.download(bridge, mode="allExcept", ids=[], startRank=value)
            self.assertEqual(events[-1]["event"], "error")
            self.assertEqual(events[-1]["kind"], "badRequest")

    def test_flat_layout_paths_match_icloudpd(self):
        self.assertEqual(
            pb.icloudpd_arguments("u", "/c", "/d", "none", False)[-4:], ["-d", "/d", "--folder-structure", "none"]
        )
        expected_dir = os.path.join(self.root, "icloudpd")
        bridge_dir = os.path.join(self.root, "bridge")
        run_icloudpd(SAMPLES, expected_dir, layout="none")
        expected = tree(expected_dir)
        for path in ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0002.JPG", "MVI_0003.MOV", "Bad_Name_.PNG",
                     "IMG_0006.HEIC", "IMG_0006.MOV"]:
            self.assertIn(path, expected)
        self.assertTrue(any(p.startswith("IMG_0002-") for p in expected), expected.keys())
        self.assertFalse(any(os.sep in p for p in expected), expected.keys())

        bridge, channel, _ = make_bridge()
        events = self.download(bridge, mode="allExcept", ids=[], dest=bridge_dir, layout="none")
        self.assertEqual(tree(bridge_dir), expected)
        self.assertEqual(events[-1]["downloaded"], 6)
        for event in events:
            for path in event.get("paths", []):
                self.assertEqual(os.path.dirname(path), bridge_dir)

        # A plain icloudpd --folder-structure none run finds everything already there, and so does the bridge.
        session, log = run_icloudpd(SAMPLES, bridge_dir, layout="none")
        self.assertEqual(session.downloads, [], log)
        bridge, channel, session = make_bridge()
        events = self.download(bridge, request_id=10, mode="allExcept", ids=[], dest=bridge_dir, layout="none")
        self.assertEqual(events[-1]["skipped"], 6)
        self.assertEqual(session.downloads, [])

    def test_events_carry_asset_rank_and_full_paths(self):
        # A long folder name, so icloudpd's 96-character log truncation would show.
        dest = os.path.join(self.root, "A folder with a long name " * 4)
        bridge, channel, _ = make_bridge()
        events = self.download(bridge, mode="allExcept", ids=[], dest=dest, xmp=True)
        downloaded = {e["asset"]: e for e in events if e["event"] == "downloaded"}
        self.assertEqual(sorted(downloaded), ["ID01", "ID02", "ID03", "ID04", "ID05", "ID06"])
        self.assertEqual([downloaded[f"ID0{i}"]["rank"] for i in range(1, 7)], list(range(6)))
        live = downloaded["ID01"]
        main = os.path.join(dest, "2023", "12", "IMG_0001.HEIC")
        self.assertEqual(live["path"], main)
        self.assertEqual(live["paths"], [main, os.path.join(dest, "2023", "12", "IMG_0001.MOV")])
        self.assertEqual(live["files"], live["paths"] + [main + ".xmp"])
        for event in downloaded.values():
            for path in event["files"]:
                self.assertTrue(os.path.isabs(path) and os.path.isfile(path), path)
                self.assertNotIn("...", path)

        # Again: every item is skipped, with the same files and ranks, and the movie of a Live Photo
        # whose image was already there is reported with both.
        os.remove(os.path.join(dest, "2024", "07", "IMG_0006.MOV"))
        bridge, channel, _ = make_bridge()
        events = self.download(bridge, request_id=11, mode="allExcept", ids=[], dest=dest, xmp=True)
        skipped = {e["asset"]: e for e in events if e["event"] == "skipped"}
        self.assertEqual(sorted(skipped), ["ID01", "ID02", "ID03", "ID04", "ID05"])
        for asset, event in skipped.items():
            self.assertEqual(event["files"], downloaded[asset]["files"])
            self.assertEqual(event["paths"], downloaded[asset]["paths"])
            self.assertEqual(event["rank"], downloaded[asset]["rank"])
        partial = next(e for e in events if e.get("asset") == "ID06")
        self.assertEqual(partial["event"], "downloaded")
        self.assertEqual(partial["paths"], [os.path.join(dest, "2024", "07", "IMG_0006.MOV")])
        self.assertEqual(partial["files"], downloaded["ID06"]["files"])

    def throttle_on(self, session, asset_id, error=None):
        """Answers the download of `asset_id`'s original the way iCloud's throttle does: HTTP 503,
        which icloudpd's session turns into PyiCloudServiceUnavailableException."""
        from pyicloud_ipd.utils import throw_on_503

        original_get = session.get

        def get(url, headers=None, stream=False):
            if f"/{asset_id}/" in url:
                if error is not None:
                    raise error
                response = FakeResponse(b"")
                response.ok = False
                response.status_code = 503
                return throw_on_503(response)
            return original_get(url, headers=headers, stream=stream)

        session.get = get

    def test_throttle_ends_the_download_with_a_run_ending_error(self):
        bridge, channel, session = make_bridge()
        self.throttle_on(session, "ID03")
        events = self.download(bridge, mode="allExcept", ids=[])
        kinds = [e["event"] for e in events]
        self.assertEqual([e["asset"] for e in events if e["event"] == "downloaded"], ["ID01", "ID02"])
        self.assertNotIn("failed", kinds)  # not one failure per remaining item
        self.assertNotIn("done", kinds)
        final = events[-1]
        self.assertEqual(final["event"], "error")
        self.assertEqual(final["kind"], "PyiCloudServiceUnavailableException")
        self.assertIn("Apple iCloud is temporary refusing to serve icloudpd", final["message"])
        self.assertEqual((final["asset"], final["rank"]), ("ID03", 2))
        self.assertEqual((final["downloaded"], final["skipped"], final["failed"]), (2, 0, 0))
        # Items after the throttled one weren't asked for.
        self.assertFalse(any("/ID04/" in url or "/ID05/" in url for url in session.downloads))
        self.assertFalse(channel.is_cancelled(9))

        # The bridge goes on serving: the next download starts normally.
        session.get = FakeSession(SAMPLES).get
        events = self.download(bridge, request_id=12, mode="allExcept", ids=[])
        self.assertEqual(events[-1]["event"], "done")

    def test_throttle_while_paging_ends_the_download_too(self):
        from pyicloud_ipd.exceptions import PyiCloudServiceUnavailableException

        samples = self.many(150)
        bridge, channel, session = make_bridge(samples)
        original = FakeAlbum.photos_request

        def photos_request(album):
            if album.offset >= 100:
                raise PyiCloudServiceUnavailableException("Apple iCloud is temporary refusing to serve icloudpd")
            return original(album)

        FakeAlbum.photos_request = photos_request
        try:
            events = self.download(bridge, mode="allExcept", ids=[])
        finally:
            FakeAlbum.photos_request = original
        self.assertEqual(events[-1]["event"], "error")
        self.assertEqual(events[-1]["kind"], "PyiCloudServiceUnavailableException")
        self.assertEqual(events[-1]["downloaded"], 100)
        self.assertNotIn("failed", [e["event"] for e in events])

    def test_lost_connection_ends_the_download(self):
        from pyicloud_ipd.exceptions import PyiCloudConnectionErrorException

        bridge, channel, session = make_bridge()
        self.throttle_on(session, "ID02", PyiCloudConnectionErrorException("Cannot connect to Apple iCloud service"))
        events = self.download(bridge, mode="only", ids=["ID02", "ID03"])
        self.assertEqual(events[-1]["event"], "error")
        self.assertEqual(events[-1]["kind"], "PyiCloudConnectionErrorException")
        self.assertNotIn("failed", [e["event"] for e in events])

    def test_other_errors_still_fail_only_their_item(self):
        bridge, channel, session = make_bridge()
        self.throttle_on(session, "ID02", ValueError("odd record"))
        events = self.download(bridge, mode="only", ids=["ID02", "ID03"])
        self.assertEqual([e["asset"] for e in events if e["event"] == "failed"], ["ID02"])
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["downloaded"], 1)


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


class IndexingSession(FakeSession):
    """Answers CheckIndexingState with `state`; `error` is raised instead when given (as session.py does)."""

    def __init__(self, samples, state=None, error=None):
        super().__init__(samples)
        self.state = state
        self.error = error

    def post(self, url, data=None, headers=None):
        if self.error is not None:
            raise self.error
        assert json.loads(data)["query"]["recordType"] == "CheckIndexingState"
        return FakeResponse({"records": [{"fields": {"state": {"value": self.state}}}]})


class IndexingTests(unittest.TestCase):
    def primary_library(self, session):
        from pyicloud_ipd.services import photos

        return photos.PhotoLibrary("https://fake", {}, session, {"zoneName": "PrimarySync"}, "private")

    def test_running_index_still_reaches_ready_and_pages(self):
        import types

        import icloudpd.authentication as auth

        session = IndexingSession(SAMPLES, state="RUNNING")
        holder = types.SimpleNamespace(private_libraries={"PrimarySync": self.primary_library(session)}, shared_libraries={})
        channel = Collector()
        original = auth.authenticator
        auth.authenticator = lambda *a, **k: FakeICloud(holder)
        try:
            icloud, library = pb.authenticate(channel, "user@example.com", "/cookies")
        finally:
            auth.authenticator = original
        self.assertEqual(library.zone_id["zoneName"], "PrimarySync")
        self.assertEqual(channel.messages, [])
        # The fake service serves paging from memory, so the bridge pages the fake library; the
        # library above proves startup, which is what RUNNING used to stop.
        bridge = pb.Bridge(channel, icloud, FakeLibrary(SAMPLES, session), "user@example.com", "/nonexistent-cookies")
        bridge.handle({"id": 7, "cmd": "page", "offset": 0, "limit": 2}, downloading=False)
        page = channel.messages[-1]
        self.assertEqual(page["event"], "page")
        self.assertEqual(page["id"], 7)
        self.assertEqual([item["filename"] for item in page["items"]], ["IMG_0001.HEIC", "IMG_0002.JPG"])
        self.assertEqual([m for m in channel.messages if m.get("event") == "error"], [])

    def test_running_sends_one_note_and_logs_a_warning(self):
        notes = []
        pb.patch_icloudpd_for_bridge(notes.append)
        pb._indexing_notice["sent"] = False
        try:
            with self.assertLogs("photo_bridge", level="WARNING") as logs:
                self.primary_library(IndexingSession(SAMPLES, state="RUNNING"))
                self.primary_library(IndexingSession(SAMPLES, state="RUNNING"))
            self.assertEqual(notes, [pb.INDEXING_NOTE])
            self.assertEqual(len(logs.records), 2)
        finally:
            pb.patch_icloudpd_for_bridge(None)
            pb._indexing_notice["sent"] = False

    def test_finished_index_state_is_silent(self):
        notes = []
        pb.patch_icloudpd_for_bridge(notes.append)
        try:
            library = self.primary_library(IndexingSession(SAMPLES, state="FINISHED"))
            self.assertEqual(library.library_type, "private")
            self.assertEqual(notes, [])
        finally:
            pb.patch_icloudpd_for_bridge(None)

    def test_setup_not_complete_still_errors(self):
        from pyicloud_ipd.exceptions import PyiCloudServiceNotActivatedException

        error = PyiCloudServiceNotActivatedException(
            "Apple iCloud setup is not complete. Please log into https://icloud.com/", "ZONE_NOT_FOUND"
        )
        with self.assertRaises(PyiCloudServiceNotActivatedException) as raised:
            self.primary_library(IndexingSession(SAMPLES, error=error))
        self.assertIn("setup is not complete", str(raised.exception))

    def test_other_indexing_states_still_error(self):
        # Anything but RUNNING with the indexing message is not what this patch tolerates.
        from pyicloud_ipd.exceptions import PyiCloudServiceNotActivatedException

        error = PyiCloudServiceNotActivatedException("Some other reason", None)
        with self.assertRaises(PyiCloudServiceNotActivatedException):
            self.primary_library(IndexingSession(SAMPLES, error=error))


class ModifySession(FakeSession):
    """CloudKit's records/modify. Each CPLAsset named in the body is removed from `samples` in place, so the
    library reads back smaller, unless `fail` gives it a serverErrorCode reason or `omit` leaves it out of the
    answer. `status` maps a request's number (from 0) to an HTTP status, `raise_at` to an exception raised
    instead, and `on_post(number)` runs before each answer. Every request is kept in `posts` as (url, body).
    A batch that sets isDeleted to 1 moves its records from `samples` to `trash`, and one that sets it to 0 moves
    them back, sorted by added date as the library lists them."""

    def __init__(self, samples, fail=None, omit=(), status=None, raise_at=None, on_post=None, trash=None):
        super().__init__(samples)
        self.samples = samples
        self.trash = [] if trash is None else trash
        self.fail = fail or {}
        self.omit = set(omit)
        self.status = status or {}
        self.raise_at = raise_at or {}
        self.on_post = on_post
        self.posts = []

    def post(self, url, data=None, headers=None):
        number = len(self.posts)
        body = json.loads(data)
        self.posts.append((url, body))
        if self.on_post is not None:
            self.on_post(number)
        if number in self.raise_at:
            raise self.raise_at[number]
        if number in self.status:
            response = FakeResponse({})
            response.ok = False
            response.status_code = self.status[number]
            return response
        records, changed = [], set()
        is_deleted = None
        for operation in body["operations"]:
            name = operation["record"]["recordName"]
            is_deleted = operation["record"]["fields"]["isDeleted"]["value"]
            if name in self.omit:
                continue
            if name in self.fail:
                records.append({"recordName": name, "serverErrorCode": "CAS_FAILED", "reason": self.fail[name]})
            else:
                records.append({"recordName": name, "recordType": "CPLAsset", "fields": {"isDeleted": {"value": is_deleted}}})
                changed.add(name)
        if is_deleted == 1:
            source, target = self.samples, self.trash
        else:
            source, target = self.trash, self.samples
        moving = [sample for sample in source if sample[1]["recordName"] in changed]
        source[:] = [sample for sample in source if sample[1]["recordName"] not in changed]
        target.extend(moving)
        if is_deleted == 0:
            target.sort(key=lambda sample: sample[1]["fields"]["addedDate"]["value"])
        response = FakeResponse({"records": records})
        response.status_code = 200
        return response


def delete_bridge(samples=None, trash=None, **options):
    """A bridge over a copy of `samples` (the library's own list is changed by deletes), with a ModifySession.
    `trash` is Recently Deleted, the same kind of list."""
    samples = list(SAMPLES if samples is None else samples)
    trash = [] if trash is None else trash
    session = ModifySession(samples, trash=trash, **options)
    library = FakeLibrary(samples, session, trash)
    channel = Collector()
    bridge = pb.Bridge(channel, FakeICloud(library), library, "user@example.com", "/nonexistent-cookies")
    return bridge, channel, session


def many_samples(count):
    return [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(count)]


class DeleteTests(unittest.TestCase):
    REQUEST_ID = 60

    def setUp(self):
        self.original_pace = pb.DELETE_PACE
        pb.DELETE_PACE = 0.0

    def tearDown(self):
        pb.DELETE_PACE = self.original_pace

    def delete(self, bridge, **request):
        # Confirmed as many items as the library holds, unless a test says otherwise.
        confirmed = len(bridge.library._samples)
        request = {"id": self.REQUEST_ID, "cmd": "delete", "confirmedCount": confirmed, **request}
        bridge.handle(request, downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == self.REQUEST_ID]

    @staticmethod
    def events(messages, name):
        return [m for m in messages if m["event"] == name]

    @staticmethod
    def names(session):
        return [op["record"]["recordName"] for _, body in session.posts for op in body["operations"]]

    def test_two_hundred_fifty_items_go_in_three_batches(self):
        bridge, channel, session = delete_bridge(many_samples(250))
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual([len(body["operations"]) for _, body in session.posts], [100, 100, 50])
        done = events[-1]
        self.assertEqual(done["event"], "deleteDone")
        self.assertEqual((done["deleted"], done["failed"], done["missing"]), (250, 0, 0))
        self.assertFalse(done["cancelled"])
        self.assertIsNone(done["stopped"])
        self.assertEqual(len(self.events(events, "deleted")), 3)
        self.assertEqual(len(bridge.library._samples), 0)
        progress = [(e["phase"], e["done"], e["total"]) for e in self.events(events, "deleteProgress")]
        self.assertIn(("finding", 100, 250), progress)
        self.assertEqual(progress[-1], ("deleting", 250, 250))

    def test_request_body_has_the_cloudkit_shape(self):
        bridge, channel, session = delete_bridge()
        self.delete(bridge, mode="only", ids=["ID02"])
        url, body = session.posts[0]
        self.assertEqual(url.split("?")[0], "https://fake/records/modify")
        self.assertIn("clientId=fake", url)
        self.assertEqual(body, {
            "atomic": False,
            "desiredKeys": ["isDeleted"],
            "operations": [{
                "operationType": "update",
                "record": {
                    "fields": {"isDeleted": {"value": 1}},
                    "recordChangeTag": "x",
                    "recordName": "A-ID02",
                    "recordType": "CPLAsset",
                },
            }],
            "zoneID": {"zoneName": "PrimarySync"},
        })

    def test_partial_failures_come_from_server_error_codes(self):
        bridge, channel, session = delete_bridge(fail={"A-ID02": "Not allowed to delete this item."})
        events = self.delete(bridge, mode="allExcept", ids=["ID06"])
        failed = self.events(events, "deleteFailed")
        self.assertEqual(failed, [{"id": self.REQUEST_ID, "event": "deleteFailed",
                                   "failures": [{"id": "ID02", "reason": "Not allowed to delete this item."}]}])
        deleted = [i for e in self.events(events, "deleted") for i in e["ids"]]
        self.assertEqual(deleted, ["ID01", "ID03", "ID04", "ID05"])
        done = events[-1]
        self.assertEqual((done["deleted"], done["failed"]), (4, 1))
        # The failed item stays in the library.
        self.assertEqual([s[0]["recordName"] for s in bridge.library._samples], ["ID02", "ID06"])

    def test_an_item_missing_from_the_answer_counts_as_failed(self):
        bridge, channel, session = delete_bridge(omit={"A-ID03"})
        events = self.delete(bridge, mode="only", ids=["ID03", "ID04"])
        failures = self.events(events, "deleteFailed")[0]["failures"]
        self.assertEqual(failures, [{"id": "ID03", "reason": "No response from iCloud."}])
        self.assertEqual(events[-1]["deleted"], 1)

    def test_an_http_error_fails_only_its_batch(self):
        bridge, channel, session = delete_bridge(many_samples(250), status={0: 400})
        events = self.delete(bridge, mode="allExcept", ids=[])
        failures = [f for e in self.events(events, "deleteFailed") for f in e["failures"]]
        self.assertEqual(len(failures), 100)
        self.assertEqual(failures[0], {"id": "N0000", "reason": "iCloud answered with HTTP 400."})
        done = events[-1]
        self.assertEqual((done["deleted"], done["failed"], done["stopped"]), (150, 100, None))
        self.assertEqual(len(session.posts), 3)

    def test_cancel_stops_before_the_next_batch(self):
        bridge, channel, session = delete_bridge(many_samples(250))

        def cancel(number):
            if number == 0:
                channel.feed(f'{{"cmd":"cancel","target":{self.REQUEST_ID}}}')

        session.on_post = cancel
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 1)
        done = events[-1]
        self.assertTrue(done["cancelled"])
        self.assertEqual((done["deleted"], done["failed"]), (100, 0))
        self.assertFalse(channel.is_cancelled(self.REQUEST_ID))  # forgotten once the run ends

    def test_pause_holds_between_batches_and_browsing_is_answered(self):
        bridge, channel, session = delete_bridge(many_samples(250))
        seen_while_paused = {}

        def on_post(number):
            if number == 0:
                channel.feed(f'{{"cmd":"pause","target":{self.REQUEST_ID}}}')
                channel.feed('{"id":61,"cmd":"count"}')
                threading.Thread(target=resume_after_count, daemon=True).start()

        def resume_after_count():
            for _ in range(500):
                if any(m.get("id") == 61 for m in channel.messages):
                    break
                threading.Event().wait(0.01)
            seen_while_paused["posts"] = len(session.posts)
            channel.feed(f'{{"cmd":"resume","target":{self.REQUEST_ID}}}')

        session.on_post = on_post
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(seen_while_paused["posts"], 1)  # the count was answered before the second batch
        self.assertEqual(next(m for m in channel.messages if m.get("id") == 61)["count"], 150)  # after the first batch
        self.assertEqual(len(session.posts), 3)
        self.assertEqual(events[-1]["deleted"], 250)
        self.assertFalse(events[-1]["cancelled"])

    def test_a_throttle_stops_the_run_with_the_items_it_did_not_reach(self):
        from pyicloud_ipd.exceptions import PyiCloudServiceUnavailableException

        throttle = PyiCloudServiceUnavailableException("Apple iCloud is temporary refusing to serve icloudpd")
        bridge, channel, session = delete_bridge(many_samples(250), raise_at={1: throttle})
        events = self.delete(bridge, mode="allExcept", ids=[])
        done = events[-1]
        self.assertEqual(done["event"], "deleteDone")
        self.assertEqual(done["stopped"], "throttled")
        self.assertEqual(done["message"], "Apple iCloud is temporary refusing to serve icloudpd")
        self.assertEqual((done["deleted"], done["failed"]), (100, 0))
        self.assertFalse(self.events(events, "deleteFailed"))
        self.assertEqual(len(session.posts), 2)
        self.assertEqual(len(bridge.library._samples), 150)

    def test_all_except_resolves_targets_without_the_excluded_ids(self):
        bridge, channel, session = delete_bridge()
        events = self.delete(bridge, mode="allExcept", ids=["ID01", "ID02"])
        targets = self.events(events, "deleteTargets")[0]["ids"]
        self.assertEqual(targets, ["ID03", "ID04", "ID05", "ID06"])
        self.assertEqual(self.names(session), ["A-ID03", "A-ID04", "A-ID05", "A-ID06"])
        self.assertEqual(events[-1]["deleted"], 4)
        self.assertEqual(events[-1]["missing"], 0)

    def test_missing_ids_are_counted_and_not_sent(self):
        bridge, channel, session = delete_bridge()
        events = self.delete(bridge, mode="only", ids=["ID02", "NOPE", "GONE"])
        self.assertEqual(self.events(events, "deleteTargets")[0]["ids"], ["ID02"])
        self.assertEqual(self.names(session), ["A-ID02"])
        self.assertEqual((events[-1]["deleted"], events[-1]["missing"]), (1, 2))

    def test_no_targets_means_no_posts(self):
        bridge, channel, session = delete_bridge()
        events = self.delete(bridge, mode="only", ids=["NOPE"])
        self.assertEqual(session.posts, [])
        timing = events[-1].pop("timing")
        self.assertEqual(events[-1], {"id": self.REQUEST_ID, "event": "deleteDone", "deleted": 0, "failed": 0,
                                      "missing": 1, "cancelled": False, "stopped": None, "message": None})
        self.assertEqual(timing["items"], 0)
        self.assertEqual(session.posts, [])
        events = self.delete(bridge, mode="allExcept", ids=[s[0]["recordName"] for s in SAMPLES])
        self.assertEqual(session.posts, [])
        self.assertEqual(events[-1]["deleted"], 0)

    def test_hinted_ranks_are_used_for_only_mode(self):
        bridge, channel, session = delete_bridge()
        events = self.delete(bridge, mode="only", ids=["ID05"], hints={"ID05": 4})
        self.assertEqual(self.events(events, "deleteTargets")[0]["ids"], ["ID05"])
        self.assertEqual(events[-1]["deleted"], 1)

    def test_a_delete_during_a_download_waits_its_turn(self):
        bridge, channel, session = delete_bridge()
        bridge.handle({"id": 62, "cmd": "delete", "mode": "allExcept", "ids": []}, downloading=True)
        self.assertEqual(len(bridge._deferred), 1)
        self.assertEqual(session.posts, [])
        self.assertEqual([m for m in channel.messages if m.get("id") == 62], [])

    def test_more_items_than_confirmed_deletes_nothing(self):
        bridge, channel, session = delete_bridge()
        events = self.delete(bridge, mode="allExcept", ids=[], confirmedCount=5)
        self.assertEqual(session.posts, [])
        self.assertEqual(self.events(events, "deleteTargets"), [])
        done = events[-1]
        self.assertEqual((done["event"], done["stopped"], done["deleted"], done["message"]),
                         ("deleteDone", "changed", 0, pb.DELETE_CHANGED_MESSAGE))
        self.assertEqual(len(bridge.library._samples), 6)

    def test_equal_or_fewer_confirmed_than_targets_proceeds(self):
        for confirmed in (6, 7):
            bridge, channel, session = delete_bridge()
            events = self.delete(bridge, mode="allExcept", ids=[], confirmedCount=confirmed)
            self.assertIsNone(events[-1]["stopped"], confirmed)
            self.assertEqual(events[-1]["deleted"], 6, confirmed)

    def test_confirmed_count_is_required_and_checked(self):
        bridge, channel, session = delete_bridge()
        bridge.handle({"id": self.REQUEST_ID, "cmd": "delete", "mode": "only", "ids": ["ID01"]}, downloading=False)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.delete(bridge, mode="only", ids=["ID01"], confirmedCount=-1)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.delete(bridge, mode="only", ids=["ID01"], confirmedCount=True)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.assertEqual(session.posts, [])

    def test_access_denied_stops_as_throttled_after_one_batch(self):
        from pyicloud_ipd.exceptions import PyiCloudAPIResponseException

        bridge, channel, session = delete_bridge(many_samples(250), raise_at={
            0: PyiCloudAPIResponseException("ACCESS_DENIED", "ACCESS_DENIED"),
        })
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 1)
        done = events[-1]
        self.assertEqual((done["stopped"], done["deleted"], done["failed"]), ("throttled", 0, 0))
        self.assertEqual(len(bridge.library._samples), 250, "the remaining items are untouched")

    def test_http_503_stops_as_throttled_after_one_batch(self):
        bridge, channel, session = delete_bridge(many_samples(250), status={0: 503})
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 1)
        done = events[-1]
        self.assertEqual((done["stopped"], done["deleted"], done["failed"]), ("throttled", 0, 0))
        self.assertEqual(self.events(events, "deleteFailed"), [])
        self.assertEqual(len(bridge.library._samples), 250)

    def test_three_fully_failed_batches_stop_as_error(self):
        bridge, channel, session = delete_bridge(many_samples(400), status={0: 400, 1: 400, 2: 400})
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 3, "no fourth batch is sent")
        done = events[-1]
        self.assertEqual((done["stopped"], done["deleted"], done["failed"]), ("error", 0, 300))
        self.assertEqual(done["message"], "iCloud answered with HTTP 400.")

    def test_a_good_batch_resets_the_failure_streak(self):
        bridge, channel, session = delete_bridge(many_samples(500), status={0: 400, 1: 400, 3: 400, 4: 400})
        events = self.delete(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 5)
        done = events[-1]
        self.assertIsNone(done["stopped"])
        self.assertEqual((done["deleted"], done["failed"]), (100, 400))

    def test_bad_requests_are_refused(self):
        bridge, channel, session = delete_bridge()
        self.delete(bridge, mode="sometimes", ids=[])
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.delete(bridge, mode="only", ids=["ID01"], batchSize=0)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.delete(bridge, mode="only", ids=["ID01"], batchSize=201)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.assertEqual(session.posts, [])


class RestoreTests(unittest.TestCase):
    """Restore moves items from Recently Deleted back into the library, with the same guards and stops as delete."""
    REQUEST_ID = 70

    def setUp(self):
        self.original_pace = pb.DELETE_PACE
        pb.DELETE_PACE = 0.0

    def tearDown(self):
        pb.DELETE_PACE = self.original_pace

    @staticmethod
    def trashed(count):
        """`count` items in Recently Deleted, added in order, none in the library."""
        return [records(f"T{i:04d}", f"TRASH_{i:04d}.JPG", "public.jpeg", ms(2021, 1, 1) + i) for i in range(count)]

    @staticmethod
    def events(messages, name):
        return [m for m in messages if m["event"] == name]

    @staticmethod
    def names(session):
        return [op["record"]["recordName"] for _, body in session.posts for op in body["operations"]]

    def restore(self, bridge, **request):
        confirmed = len(bridge.library._trash)
        request = {"id": self.REQUEST_ID, "cmd": "restore", "confirmedCount": confirmed, **request}
        bridge.handle(request, downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == self.REQUEST_ID]

    def test_restore_moves_recently_deleted_items_back_into_the_library(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(3))
        events = self.restore(bridge, mode="allExcept", ids=[])
        self.assertEqual(events[-1]["event"], "deleteDone")
        self.assertEqual((events[-1]["deleted"], events[-1]["failed"], events[-1]["stopped"]), (3, 0, None))
        self.assertEqual(bridge.library._trash, [])
        self.assertEqual(len(bridge.library._samples), 9)

    def test_restore_request_body_sets_isDeleted_to_zero(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(1))
        self.restore(bridge, mode="only", ids=["T0000"])
        url, body = session.posts[0]
        self.assertEqual(url.split("?")[0], "https://fake/records/modify")
        self.assertEqual(body, {
            "atomic": False,
            "desiredKeys": ["isDeleted"],
            "operations": [{
                "operationType": "update",
                "record": {
                    "fields": {"isDeleted": {"value": 0}},
                    "recordChangeTag": "x",
                    "recordName": "A-T0000",
                    "recordType": "CPLAsset",
                },
            }],
            "zoneID": {"zoneName": "PrimarySync"},
        })

    def test_restore_walks_recently_deleted_and_never_touches_the_library(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(2))
        events = self.restore(bridge, mode="allExcept", ids=["T0001"])
        self.assertEqual(self.events(events, "deleteTargets")[0]["ids"], ["T0000"])
        self.assertEqual(self.names(session), ["A-T0000"])
        # The six library items stay; the restored one joins them, and the excluded one stays in Recently Deleted.
        self.assertEqual(len(bridge.library._samples), 7)
        self.assertEqual([s[0]["recordName"] for s in bridge.library._trash], ["T0001"])

    def test_restore_only_mode_counts_items_not_in_recently_deleted_as_missing(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(1))
        events = self.restore(bridge, mode="only", ids=["T0000", "ID01"])
        self.assertEqual(self.names(session), ["A-T0000"])
        self.assertEqual((events[-1]["deleted"], events[-1]["missing"]), (1, 1))

    def test_restore_refuses_more_items_than_confirmed(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(3))
        events = self.restore(bridge, mode="allExcept", ids=[], confirmedCount=2)
        self.assertEqual(session.posts, [])
        done = events[-1]
        self.assertEqual((done["stopped"], done["deleted"]), ("changed", 0))
        self.assertIn("nothing was recovered", done["message"])
        self.assertEqual(len(bridge.library._trash), 3)

    def test_restore_throttle_stops_with_the_items_it_did_not_reach(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(250), status={1: 503})
        events = self.restore(bridge, mode="allExcept", ids=[])
        done = events[-1]
        self.assertEqual((done["stopped"], done["deleted"], done["failed"]), ("throttled", 100, 0))
        self.assertEqual(len(session.posts), 2)
        self.assertEqual(len(bridge.library._trash), 150, "the items not reached stay in Recently Deleted")

    def test_restore_partial_failures_stay_in_recently_deleted(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(3), fail={"A-T0001": "Not allowed to restore this item."})
        events = self.restore(bridge, mode="allExcept", ids=[])
        failed = self.events(events, "deleteFailed")
        self.assertEqual(failed[0]["failures"], [{"id": "T0001", "reason": "Not allowed to restore this item."}])
        self.assertEqual(events[-1]["deleted"], 2)
        self.assertEqual([s[0]["recordName"] for s in bridge.library._trash], ["T0001"])

    def test_three_fully_failed_restore_batches_stop_as_error(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(400), status={0: 400, 1: 400, 2: 400})
        events = self.restore(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 3)
        self.assertEqual((events[-1]["stopped"], events[-1]["failed"]), ("error", 300))

    def test_restore_cancel_stops_before_the_next_batch(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(250))

        def cancel(number):
            if number == 0:
                channel.feed(f'{{"cmd":"cancel","target":{self.REQUEST_ID}}}')

        session.on_post = cancel
        events = self.restore(bridge, mode="allExcept", ids=[])
        self.assertEqual(len(session.posts), 1)
        self.assertTrue(events[-1]["cancelled"])
        self.assertEqual(events[-1]["deleted"], 100)

    def test_a_restore_during_a_download_waits_its_turn(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(1))
        bridge.handle({"id": 71, "cmd": "restore", "mode": "allExcept", "ids": [], "confirmedCount": 1}, downloading=True)
        self.assertEqual(len(bridge._deferred), 1)
        self.assertEqual(session.posts, [])

    def test_delete_then_restore_round_trips_the_library(self):
        bridge, channel, session = delete_bridge()
        DeleteTests.delete(self, bridge, mode="only", ids=["ID02", "ID05"])
        self.assertEqual(len(bridge.library._trash), 2)
        restored = self.restore(bridge, mode="allExcept", ids=[])
        self.assertEqual(restored[-1]["deleted"], 2)
        self.assertEqual(bridge.library._trash, [])
        self.assertEqual([s[0]["recordName"] for s in bridge.library._samples], [s[0]["recordName"] for s in SAMPLES])

    def test_page_and_count_read_recently_deleted(self):
        bridge, channel, session = delete_bridge(trash=self.trashed(3))
        bridge.handle({"id": 72, "cmd": "count", "album": "recentlyDeleted"}, downloading=False)
        self.assertEqual(channel.messages[-1]["count"], 3)
        bridge.handle({"id": 73, "cmd": "page", "album": "recentlyDeleted", "offset": 1, "limit": 5}, downloading=False)
        page = channel.messages[-1]
        self.assertEqual([item["id"] for item in page["items"]], ["T0001", "T0002"])
        self.assertEqual([item["rank"] for item in page["items"]], [1, 2])
        self.assertNotIn("daysLeft", page["items"][0], "the bridge reports no days left")
        bridge.handle({"id": 74, "cmd": "count"}, downloading=False)
        self.assertEqual(channel.messages[-1]["count"], 6, "without an album, the library")
        bridge.handle({"id": 75, "cmd": "count", "album": "library"}, downloading=False)
        self.assertEqual(channel.messages[-1]["count"], 6)

    def test_an_unknown_album_is_refused(self):
        bridge, channel, session = delete_bridge()
        bridge.handle({"id": 76, "cmd": "page", "album": "bogus", "offset": 0, "limit": 5}, downloading=False)
        self.assertEqual((channel.messages[-1]["event"], channel.messages[-1]["kind"]), ("error", "badRequest"))
        bridge.handle({"id": 77, "cmd": "count", "album": "bogus"}, downloading=False)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")
        self.assertEqual(session.posts, [])


class TimingTests(unittest.TestCase):
    """R9: every request's record queries, reply bytes and seconds, in its final event and in one stderr line."""

    def test_page_reply_carries_its_timing_and_logs_the_line(self):
        bridge, channel, session = make_bridge()
        with self.assertLogs(pb.LOGGER, level="INFO") as logs:
            bridge.handle({"id": 60, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        timing = channel.messages[-1]["timing"]
        self.assertEqual((timing["queries"], timing["items"]), (1, 6))
        self.assertGreater(timing["bytes"], 0)
        self.assertGreaterEqual(timing["seconds"], 0)
        line = next(text for text in logs.output if "timing cmd=page" in text)
        self.assertIn("timing cmd=page queries=1 items=6 bytes=%d seconds=" % timing["bytes"], line)

    def test_two_hundred_items_are_two_queries_and_say_so(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(450)]
        bridge, channel, session = make_bridge(samples)
        bridge.handle({"id": 61, "cmd": "page", "offset": 120, "limit": 200}, downloading=False)
        self.assertEqual(channel.messages[-1]["timing"]["queries"], 2)
        self.assertEqual(channel.messages[-1]["timing"]["items"], 200)

    def test_stats_and_download_final_events_carry_timing(self):
        samples = [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(250)]
        bridge, channel, session = make_bridge(samples)
        bridge.handle({"id": 62, "cmd": "stats"}, downloading=False)
        final = channel.messages[-1]
        self.assertEqual(final["event"], "stats")
        # Three pages, and the short last page costs pyicloud's empty query too (as it did before).
        self.assertEqual((final["timing"]["queries"], final["timing"]["items"]), (4, 250))

        with tempfile.TemporaryDirectory() as root:
            bridge, channel, session = make_bridge()
            bridge.handle({"id": 63, "cmd": "download", "dest": root, "layout": "month", "mode": "allExcept",
                           "ids": []}, downloading=False)
            done = channel.messages[-1]
            self.assertEqual(done["event"], "done")
            self.assertEqual(done["timing"]["items"], 6)
            self.assertGreaterEqual(done["timing"]["queries"], 1)

    def test_the_first_query_logs_results_limit_against_records(self):
        bridge, channel, session = make_bridge()
        pb._FIRST_QUERY_LOGGED["done"] = False
        with self.assertLogs(pb.LOGGER, level="INFO") as logs:
            bridge.handle({"id": 64, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        self.assertIn("query resultsLimit=12 records=12", "\n".join(logs.output))


class LeanKeysTests(unittest.TestCase):
    """R8: listings ask for LISTING_KEYS only, and the items they show are the same as with every field."""

    def test_listing_keys_are_real_fields_of_the_full_query(self):
        album = FakeAlbum(SAMPLES, FakeSession(SAMPLES))
        full = album._list_query_gen(0, "list")["desiredKeys"]
        self.assertTrue(set(pb.LISTING_KEYS) <= set(full))
        self.assertLess(len(pb.LISTING_KEYS), len(full) // 2)

    def test_describe_is_the_same_for_the_listing_fields_only(self):
        from pyicloud_ipd.services.photos import PhotoAsset

        junk = {"locationEnc": {"type": "BYTES", "value": "AAAA"}, "resJPEGLargeRes": res("X", "large"),
                "keywordsEnc": {"type": "BYTES", "value": "BBBB"}}
        keys = set(pb.LISTING_KEYS)
        for master, asset in SAMPLES:
            fat_master = {**master, "fields": {**master["fields"], **junk}}
            lean = PhotoAsset(only_fields(fat_master, keys), only_fields(asset, keys))
            self.assertNotIn("locationEnc", only_fields(fat_master, keys)["fields"])
            self.assertEqual(pb.describe(lean), pb.describe(PhotoAsset(fat_master, asset)))

    def test_page_and_stats_queries_are_lean_and_download_walks_are_not(self):
        bridge, channel, session = make_bridge()
        bridge.handle({"id": 70, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        self.assertEqual(set(session.bodies[-1]["desiredKeys"]), set(pb.LISTING_KEYS))
        bridge.handle({"id": 71, "cmd": "stats"}, downloading=False)
        self.assertEqual(set(session.bodies[-1]["desiredKeys"]), set(pb.LISTING_KEYS))
        with tempfile.TemporaryDirectory() as root:
            bridge.handle({"id": 72, "cmd": "download", "dest": root, "layout": "month", "mode": "allExcept",
                           "ids": []}, downloading=False)
        walk_keys = [b["desiredKeys"] for b in session.bodies if "desiredKeys" in b]
        self.assertIn("locationEnc", walk_keys[-1])
        self.assertEqual(walk_keys[-1], FakeAlbum(SAMPLES, FakeSession(SAMPLES))._list_query_gen(0, "list")["desiredKeys"])

    def test_page_items_are_unchanged_by_the_lean_query(self):
        junk = {"locationEnc": {"type": "BYTES", "value": "AAAA"}}
        fat = [(dict(m, fields={**m["fields"], **junk}), a) for m, a in SAMPLES]
        bridge, channel, _ = make_bridge(fat)
        bridge.handle({"id": 73, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        plain, plain_channel, _ = make_bridge(SAMPLES)
        plain.handle({"id": 74, "cmd": "page", "offset": 0, "limit": 6}, downloading=False)
        self.assertEqual(channel.messages[-1]["items"], plain_channel.messages[-1]["items"])


class BrowsingDuringDownloadTests(unittest.TestCase):
    """R10: browsing is answered between chunks of a file, at most every SERVE_INTERVAL; long requests still wait."""

    def use_clock(self, clock):
        original = pb.CLOCK
        pb.CLOCK = clock
        self.addCleanup(setattr, pb, "CLOCK", original)

    def download(self, bridge, **request):
        with tempfile.TemporaryDirectory() as root:
            bridge.handle({"id": 9, "cmd": "download", "dest": root, "layout": "month", "xmp": False, **request},
                          downloading=False)
        return [m for m in bridge.channel.messages if m.get("id") == 9]

    def test_a_page_is_answered_before_the_download_ends_and_a_stats_waits_for_it(self):
        bridge, channel, session = make_bridge()
        clock = {"now": 0.0}
        self.use_clock(lambda: clock["now"])

        def on_chunk(n):
            clock["now"] += 0.1
            if n == 5:
                channel.feed('{"id":50,"cmd":"page","offset":0,"limit":1}')
                channel.feed('{"id":51,"cmd":"stats"}')

        url, read = DownloadTests.big_download(self, bridge, session, on_chunk, chunks=50)
        events = self.download(bridge, mode="only", ids=["ID02"])
        self.assertEqual(read["n"], 50)
        self.assertEqual(events[-1]["event"], "done")
        messages = channel.messages
        page_at = next(i for i, m in enumerate(messages) if m.get("id") == 50)
        done_at = next(i for i, m in enumerate(messages) if m.get("id") == 9 and m.get("event") == "done")
        self.assertLess(page_at, done_at)
        self.assertEqual(messages[page_at]["items"][0]["id"], "ID01")
        self.assertEqual(len(bridge._deferred), 1)
        channel.close()
        bridge.serve()
        stats = [m for m in channel.messages if m.get("id") == 51 and m.get("event") == "stats"]
        self.assertEqual(len(stats), 1)

    def test_browsing_between_chunks_is_answered_at_most_every_interval(self):
        bridge, channel, session = make_bridge()
        clock = {"now": 0.0}
        self.use_clock(lambda: clock["now"])
        served = []
        bridge.serve_waiting = lambda: served.append(clock["now"])
        run = pb._DownloadRun(bridge, 9, None)
        for now in (0.0, 0.1, 0.2, 0.25, 0.3, 0.45, 0.5):
            clock["now"] = now
            run._serve_browsing_if_due()
        self.assertEqual(served, [0.0, 0.25, 0.5])


class PrefetchTests(unittest.TestCase):
    """R11: pages fetched ahead on worker threads, off by default, and one page at a time after a throttle."""

    def setUp(self):
        pb.LISTING_STATE["throttled"] = False
        self.addCleanup(pb.LISTING_STATE.__setitem__, "throttled", False)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    @staticmethod
    def many(count):
        return [records(f"N{i:04d}", f"IMG_{i:04d}.JPG", "public.jpeg", ms(2020, 1, 1) + i) for i in range(count)]

    @staticmethod
    def walked(album, depth):
        return [(rank, asset.id) for rank, asset in pb.walk(album, 0, depth)]

    def test_the_same_items_at_every_depth(self):
        samples = self.many(2050)
        plain = self.walked(FakeAlbum(samples, FakeSession(samples)), 1)
        ahead = self.walked(FakeAlbum(samples, FakeSession(samples)), 3)
        self.assertEqual(len(plain), 2050)
        self.assertEqual(ahead, plain)
        self.assertEqual(plain[0], (0, "N0000"))

    def test_depth_three_is_at_least_twice_as_fast_when_queries_are_slow(self):
        samples = self.many(2050)

        def timed(depth):
            album = FakeAlbum(samples, FakeSession(samples), delay=0.02)
            started = time.monotonic()
            self.walked(album, depth)
            return time.monotonic() - started

        one, three = timed(1), timed(3)
        self.assertLess(three * 2, one, (one, three))

    def test_a_removal_in_the_middle_still_visits_every_item_once(self):
        samples = self.many(1000)
        album = FakeAlbum(samples, FakeSession(samples))
        count = {"n": 0}

        def before():
            count["n"] += 1
            if count["n"] == 4:
                del samples[150]

        album.session.before_query = before
        visited = [asset_id for _, asset_id in self.walked(album, 3)]
        self.assertEqual(len(visited), len(set(visited)))
        self.assertTrue({f"N{i:04d}" for i in range(1000) if i != 150} <= set(visited))

    def test_a_download_with_prefetch_gets_the_same_files(self):
        samples = self.many(250)
        results = []
        for depth in (1, 3):
            with tempfile.TemporaryDirectory() as root:
                bridge, channel, session = make_bridge(samples)
                bridge.handle({"id": 80, "cmd": "download", "dest": root, "layout": "month", "mode": "allExcept",
                               "ids": [], "prefetch": depth}, downloading=False)
                done = channel.messages[-1]
                results.append((done["downloaded"], sorted(tree(root))))
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0][0], 250)

    def test_a_throttle_in_a_worker_ends_the_download_and_drops_to_one_page(self):
        from pyicloud_ipd.exceptions import PyiCloudServiceUnavailableException

        samples = self.many(1000)
        bridge, channel, session = make_bridge(samples)
        count = {"n": 0}

        def before():
            count["n"] += 1
            if count["n"] == 4:
                raise PyiCloudServiceUnavailableException("Apple iCloud is temporary refusing to serve icloudpd")

        bridge.library.before_query = before
        with tempfile.TemporaryDirectory() as root:
            bridge.handle({"id": 81, "cmd": "download", "dest": root, "layout": "month", "mode": "allExcept",
                           "ids": [], "prefetch": 3}, downloading=False)
        events = [m for m in channel.messages if m.get("id") == 81]
        self.assertEqual(events[-1]["event"], "error")
        self.assertEqual(events[-1]["kind"], "PyiCloudServiceUnavailableException")
        self.assertTrue(pb.LISTING_STATE["throttled"])
        self.assertEqual(pb.listing_depth(3), 1)

    def test_prefetch_is_off_by_default_and_checked(self):
        self.assertEqual(pb.parse_prefetch({}), 1)
        self.assertEqual(pb.parse_prefetch({"prefetch": 2}), 2)
        self.assertEqual(pb.parse_prefetch({"prefetch": 9}), pb.MAX_PREFETCH)
        for bad in (0, -1, True, "2", 2.0):
            with self.assertRaises(pb.RequestError):
                pb.parse_prefetch({"prefetch": bad})
        bridge, channel, _ = make_bridge()
        bridge.handle({"id": 82, "cmd": "stats", "prefetch": "two"}, downloading=False)
        self.assertEqual(channel.messages[-1]["kind"], "badRequest")

    def test_stats_with_prefetch_reports_the_same_sizes(self):
        samples = self.many(350)

        def run(depth):
            bridge, channel, _ = make_bridge(samples)
            bridge.handle({"id": 83, "cmd": "stats", "prefetch": depth}, downloading=False)
            sizes = {}
            for event in channel.messages:
                if event.get("id") == 83 and event["event"] == "statsProgress":
                    sizes.update(event["sizes"])
            final = channel.messages[-1]
            return sizes, (final["done"], final["total"], final["bytes"], final["complete"])

        self.assertEqual(run(1), run(3))
        self.assertEqual(run(3)[1][0], 350)

    def test_the_session_file_lock_is_held_while_a_file_is_written(self):
        path = os.path.join(self.tmp.name, "session.json")
        with pb._guarded_open(path, "w", encoding="utf-8") as handle:
            handle.write("{}")
            self.assertFalse(pb._SESSION_FILE_LOCK.acquire(blocking=False))
        self.assertTrue(pb._SESSION_FILE_LOCK.acquire(blocking=False))
        pb._SESSION_FILE_LOCK.release()
        with pb._guarded_open(path, encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "{}")


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
