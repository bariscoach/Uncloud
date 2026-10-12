"""Uncloud's long-running bridge to the iCloud Photos library.

Speaks JSON lines: requests arrive on stdin, responses and events leave on stdout, and
everything else (Python logging, stray prints) goes to stderr. It signs in exactly the way
icloudpd does and downloads with icloudpd's own `download_builder`, so a hand-picked item
lands at the path, with the name, live-photo movie and sidecar, that a full icloudpd run
would give it, and that later run reports it as "already exists".

Usage: python3.13 -I -B photo_bridge.py -u APPLE_ID --cookie-directory DIR

Startup events: {"event":"needPassword"} (answer with one line {"password":"..."}),
{"event":"signInRequired"} (two-factor needed; the bridge exits), {"event":"ready","count":N},
or {"event":"error","kind":...,"message":...}.

Requests, each with an "id" that every reply carries:
  {"cmd":"page","offset":O,"limit":L}  -> {"event":"page","offset":O,"items":[...]}
      items oldest first (icloudpd's order): {id, filename, created, type, size, thumbURL}
  {"cmd":"count"}                     -> {"event":"count","count":N}
  {"cmd":"albums"}                    -> {"event":"albums","albums":[names]}  (no smart albums)
  {"cmd":"download","mode":"only"|"allExcept","ids":[...],"dest":DIR,"layout":"month"|"album",
   "album":NAME,"xmp":BOOL,"hints":{id: rank}}
      -> {"event":"progress","done":D,"total":T} whenever either changes, then per item one of
         {"event":"downloaded","id","filename","path","paths"}, {"event":"skipped","id","filename","path"},
         {"event":"failed","id","filename","reason"}; finally {"event":"done",...counts,"cancelled":BOOL}
  {"cmd":"cancel","target":ID}        stops that download after the current item.
Errors: {"id"?, "event":"error","kind":...,"message":...}. Closing stdin or SIGTERM stops the bridge.
The password is never written anywhere.
"""

import multiprocessing
import threading


class _Value:
    def __init__(self, typecode, value):
        self.value = value


# The app sandbox forbids the named semaphores behind multiprocessing.Lock and RawValue, which
# icloudpd's Counter uses. The bridge is single-threaded where icloudpd runs, so a thread lock
# and a plain value are equivalent. This must run before icloudpd or pyicloud_ipd is imported.
multiprocessing.Lock = threading.Lock
multiprocessing.RawValue = _Value

import copy  # noqa: E402
import datetime  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402
import queue  # noqa: E402
import sys  # noqa: E402
from collections import deque  # noqa: E402
from functools import partial  # noqa: E402
from itertools import islice  # noqa: E402
from typing import Any, Callable, Dict, Iterable, List, Optional  # noqa: E402

# icloudpd's own page size; also the largest window fetched by one request.
PAGE_CHUNK = 100
MAX_PAGE_LIMIT = 500
# Above this share of the library, hint lookups cost more than one pass over it.
HINT_FRACTION = 0.3
# Ranks closer than this are fetched in one window.
HINT_GAP = 25

LOGGER = logging.getLogger("photo_bridge")

# Errors icloudpd logs and then recovers from; they don't fail an item.
_TRANSIENT_ERRORS = (
    "Session error, re-authenticating...",
    "Error downloading %s, retrying after %s seconds...",
    "Could not convert photo created date to local timezone (%s)",
    "Photo created date was not valid (%s)",
)


class NeedsSignIn(Exception):
    """Signing in needs the user: two-factor, or no saved password."""


class RequestError(Exception):
    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind


# MARK: - Channel


class Channel:
    """Writes protocol messages, and reads requests and passwords from stdin on a thread."""

    def __init__(self, out: Any):
        self._out = out
        self._write_lock = threading.Lock()
        self._requests: "queue.Queue[Optional[Dict[str, Any]]]" = queue.Queue()
        self._passwords: "queue.Queue[Optional[str]]" = queue.Queue()
        self._cancel_lock = threading.Lock()
        self._cancelled: set = set()
        self.closed = threading.Event()

    def send(self, message: Dict[str, Any]) -> None:
        line = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        with self._write_lock:
            try:
                self._out.write(line + "\n")
                self._out.flush()
            except (BrokenPipeError, OSError, ValueError):
                self.close()

    def error(self, request_id: Any, kind: str, message: str) -> None:
        reply: Dict[str, Any] = {"event": "error", "kind": kind, "message": message}
        if request_id is not None:
            reply["id"] = request_id
        self.send(reply)

    def start_reader(self, stream: Any) -> threading.Thread:
        thread = threading.Thread(target=self._read, args=(stream,), daemon=True)
        thread.start()
        return thread

    def feed(self, line: str) -> None:
        """Routes one input line. Passwords never reach the request queue or any log."""
        line = line.strip()
        if not line:
            return
        try:
            message = json.loads(line)
        except ValueError:
            # Don't echo the line: it could be a password sent the wrong way.
            self.error(None, "badRequest", "A request wasn't valid JSON.")
            return
        if not isinstance(message, dict):
            self.error(None, "badRequest", "A request wasn't a JSON object.")
            return
        if "password" in message:
            password = message.get("password")
            self._passwords.put(password if isinstance(password, str) else "")
            return
        if message.get("cmd") == "cancel":
            with self._cancel_lock:
                self._cancelled.add(message.get("target"))
            return
        self._requests.put(message)

    def close(self) -> None:
        if not self.closed.is_set():
            self.closed.set()
            self._requests.put(None)
            self._passwords.put(None)

    def _read(self, stream: Any) -> None:
        try:
            while True:
                line = stream.readline()
                if not line:
                    break
                self.feed(line)
        except (OSError, ValueError):
            pass
        self.close()

    def next_request(self) -> Optional[Dict[str, Any]]:
        """Blocks until a request arrives; None once stdin closes."""
        if self.closed.is_set() and self._requests.empty():
            return None
        return self._requests.get()

    def poll_request(self) -> Optional[Dict[str, Any]]:
        """A waiting request, or None."""
        try:
            return self._requests.get_nowait()
        except queue.Empty:
            return None

    def read_password(self) -> Optional[str]:
        self.send({"event": "needPassword"})
        return self._passwords.get()

    def is_cancelled(self, request_id: Any) -> bool:
        if self.closed.is_set():
            return True
        with self._cancel_lock:
            return request_id in self._cancelled


# MARK: - icloudpd configuration


def icloudpd_arguments(
    username: str, cookie_directory: str, directory: Optional[str], layout: str, xmp: bool
) -> List[str]:
    """The arguments ICloudExportEngine passes icloudpd for the same export."""
    args = [
        "-u", username,
        "--password-provider", "console",
        "--mfa-provider", "console",
        "--cookie-directory", cookie_directory,
        "--no-progress-bar",
        "--live-photo-mov-filename-policy", "original",
    ]
    if directory is not None:
        args += ["-d", directory, "--folder-structure", "{:%Y/%m}" if layout == "month" else "none"]
    if xmp:
        args.append("--xmp-sidecar")
    return args


class DownloadPlan:
    """icloudpd's per-user download wiring, built with icloudpd's own parser and builders the way
    `icloudpd.base._process_all_users_once` builds them."""

    def __init__(self, args: List[str], logger: logging.Logger):
        from icloudpd import base, cli
        from icloudpd.filename_policies import create_filename_builder
        from pyicloud_ipd.live_photo_mov_filename_policy import LivePhotoMovFilenamePolicy

        global_config, user_configs = cli.parse(args)
        user_config = user_configs[0]
        self.global_config = global_config
        self.user_config = user_config
        lp_filename_generator = (
            base.lp_filename_original
            if user_config.live_photo_mov_filename_policy == LivePhotoMovFilenamePolicy.ORIGINAL
            else base.lp_filename_concatinator
        )
        filename_builder = create_filename_builder(
            user_config.file_match_policy, base.build_filename_cleaner(user_config.keep_unicode_in_filenames)
        )
        self.filename_builder = filename_builder
        self.passer = partial(
            base.where_builder,
            logger,
            user_config.skip_videos,
            user_config.skip_created_before,
            user_config.skip_created_after,
            user_config.skip_photos,
            filename_builder,
        )
        self.downloader = partial(
            base.download_builder,
            logger,
            user_config.folder_structure,
            user_config.directory,
            user_config.sizes,
            user_config.force_size,
            global_config.only_print_filenames,
            user_config.set_exif_datetime,
            user_config.skip_live_photos,
            user_config.live_photo_size,
            user_config.dry_run,
            user_config.file_match_policy,
            user_config.xmp_sidecar,
            lp_filename_generator,
            filename_builder,
            user_config.align_raw,
        )


class Capture(logging.Handler):
    """Collects what icloudpd's download functions report about one item."""

    def __init__(self) -> None:
        super().__init__(logging.DEBUG)
        self.reset()

    def reset(self) -> None:
        self.downloaded: List[str] = []
        self.existing: List[str] = []
        self.errors: List[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        args = record.args if isinstance(record.args, tuple) else ()
        if record.msg == "Downloaded %s" and args:
            self.downloaded.append(str(args[0]))
        elif record.msg == "%s already exists" and args:
            self.existing.append(str(args[0]))
        elif record.levelno >= logging.ERROR and record.msg not in _TRANSIENT_ERRORS:
            try:
                self.errors.append(record.getMessage())
            except Exception:  # noqa: BLE001
                self.errors.append(str(record.msg))


def patch_icloudpd_for_bridge() -> None:
    """icloudpd shortens paths in its log lines; the bridge reads full paths from them."""
    from icloudpd import base

    base.truncate_middle = lambda text, _length: text


# MARK: - Library access


def fetch_assets(album: Any, offset: int, limit: int) -> List[Any]:
    """Items `offset..<offset+limit` of an album, in icloudpd's order, with its own paging."""
    if limit <= 0:
        return []
    view = copy.copy(album)
    view.offset = max(0, offset)
    view.page_size = min(limit, PAGE_CHUNK)
    return list(islice(view.photos, limit))


def thumb_url(asset: Any) -> Optional[str]:
    for record in (asset._asset_record, asset._master_record):
        entry = record.get("fields", {}).get("resJPEGThumbRes")
        if entry:
            url = entry.get("value", {}).get("downloadURL")
            if url:
                return str(url)
    return None


def describe(asset: Any) -> Dict[str, Any]:
    from pyicloud_ipd.item_type import AssetItemType

    try:
        moment = asset.asset_date
        if moment.tzinfo is None:
            moment = moment.astimezone()
        created: Optional[str] = (
            moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        )
    except (ValueError, OSError, OverflowError):
        created = None
    try:
        size: Optional[int] = int(asset.size)
    except (KeyError, TypeError, ValueError):
        size = None
    return {
        "id": asset.id,
        "filename": asset.filename,
        "created": created,
        "type": "movie" if asset.item_type == AssetItemType.MOVIE else "image",
        "size": size,
        "thumbURL": thumb_url(asset),
    }


def hint_windows(ranks: Iterable[int]) -> List[range]:
    """Groups sorted ranks into fetch windows of at most PAGE_CHUNK items."""
    windows: List[range] = []
    start = end = None
    for rank in sorted(set(ranks)):
        if start is not None and end is not None and rank - end <= HINT_GAP and rank - start < PAGE_CHUNK:
            end = rank
            continue
        if start is not None and end is not None:
            windows.append(range(start, end + 1))
        start = end = rank
    if start is not None and end is not None:
        windows.append(range(start, end + 1))
    return windows


# MARK: - Bridge


class Bridge:
    def __init__(
        self,
        channel: Channel,
        icloud: Any,
        library: Any,
        username: str,
        cookie_directory: str,
        plan_factory: Callable[[List[str], logging.Logger], DownloadPlan] = DownloadPlan,
    ):
        self.channel = channel
        self.icloud = icloud
        self.library = library
        self.username = username
        self.cookie_directory = cookie_directory
        self.plan_factory = plan_factory
        self._albums: Optional[Dict[str, Any]] = None
        self._deferred: deque = deque()
        self.download_logger = logging.getLogger("photo_bridge.download")
        self.download_logger.setLevel(logging.DEBUG)
        self.capture = Capture()
        self.download_logger.addHandler(self.capture)

    # Serving

    def serve(self) -> None:
        while True:
            request = self._deferred.popleft() if self._deferred else self.channel.next_request()
            if request is None:
                return
            self.handle(request, downloading=False)

    def handle(self, request: Dict[str, Any], downloading: bool) -> None:
        request_id = request.get("id")
        command = request.get("cmd")
        try:
            if command == "page":
                offset = int(request.get("offset", 0))
                limit = max(0, min(int(request.get("limit", 200)), MAX_PAGE_LIMIT))
                items = [describe(a) for a in fetch_assets(self.library.all, offset, limit)]
                self.channel.send({"id": request_id, "event": "page", "offset": offset, "items": items})
            elif command == "count":
                self.channel.send({"id": request_id, "event": "count", "count": len(self.library.all)})
            elif command == "albums":
                from pyicloud_ipd.services.photos import PhotoLibrary

                names = [n for n in self.albums(refresh=True) if n not in PhotoLibrary.SMART_FOLDERS]
                self.channel.send({"id": request_id, "event": "albums", "albums": names})
            elif command == "download":
                if downloading:
                    self._deferred.append(request)
                else:
                    self.download(request)
            else:
                raise RequestError("badRequest", f"Unknown command {command!r}.")
        except RequestError as error:
            self.channel.error(request_id, error.kind, str(error))
        except Exception as error:  # noqa: BLE001
            self.channel.error(request_id, type(error).__name__, str(error))

    def serve_waiting(self) -> None:
        """Answers browsing requests that arrived during a download, between its items."""
        while True:
            request = self.channel.poll_request()
            if request is None:
                return
            self.handle(request, downloading=True)

    def albums(self, refresh: bool = False) -> Dict[str, Any]:
        if self._albums is None or refresh:
            self._albums = dict(self.library.albums)
        return self._albums

    # Downloading

    def download(self, request: Dict[str, Any]) -> None:
        request_id = request.get("id")
        mode = request.get("mode")
        if mode not in ("only", "allExcept"):
            raise RequestError("badRequest", "mode must be only or allExcept.")
        layout = request.get("layout", "month")
        if layout not in ("month", "album"):
            raise RequestError("badRequest", "layout must be month or album.")
        destination = request.get("dest")
        if not isinstance(destination, str) or not destination:
            raise RequestError("badRequest", "dest is required.")
        ids = set(str(i) for i in (request.get("ids") or []))
        hints = request.get("hints") or {}

        if layout == "album":
            name = request.get("album")
            album = self.albums().get(name) if isinstance(name, str) else None
            if album is None:
                raise RequestError("albumNotFound", f"There's no album named {name!r}.")
        else:
            album = self.library.all

        args = icloudpd_arguments(
            self.username, self.cookie_directory, destination, layout, bool(request.get("xmp"))
        )
        plan = self.plan_factory(args, self.download_logger)
        run = _DownloadRun(self, request_id, plan)

        if mode == "allExcept":
            run.set_total(len(album))
            for asset in album:
                if run.should_stop():
                    break
                if asset.id in ids:
                    run.set_total(run.total - 1)
                    continue
                run.process(asset)
        else:
            remaining = set(ids)
            if layout == "month":
                run.set_total(len(remaining))
                for asset in self._hinted(album, remaining, hints, run):
                    if run.should_stop():
                        break
                    remaining.discard(asset.id)
                    run.process(asset)
            else:
                # Membership is only known by walking the album; the total grows with each match.
                run.set_total(0)
            if remaining and not run.should_stop():
                for asset in album:
                    if run.should_stop():
                        break
                    if asset.id in remaining:
                        remaining.discard(asset.id)
                        if layout == "album":
                            run.set_total(run.total + 1)
                        run.process(asset)
                        if not remaining:
                            break
                    else:
                        run.idle()
            if layout == "month" and not run.should_stop() and remaining:
                # Items deleted from iCloud since they were selected.
                run.set_total(run.total - len(remaining))
        run.finish()

    def _hinted(self, album: Any, remaining: set, hints: Dict[str, Any], run: "_DownloadRun") -> Iterable[Any]:
        ranks = []
        for asset_id, rank in hints.items():
            if asset_id in remaining and isinstance(rank, int) and rank >= 0:
                ranks.append(rank)
        if not ranks:
            return
        try:
            library_size = len(album)
        except Exception:  # noqa: BLE001
            return
        if len(ranks) > library_size * HINT_FRACTION:
            return
        for window in hint_windows(ranks):
            if run.should_stop():
                return
            for asset in fetch_assets(album, window.start, len(window)):
                if asset.id in remaining:
                    yield asset


class _DownloadRun:
    def __init__(self, bridge: Bridge, request_id: Any, plan: DownloadPlan):
        self.bridge = bridge
        self.channel = bridge.channel
        self.request_id = request_id
        self.plan = plan
        self.total = 0
        self.done = 0
        self.counts = {"downloaded": 0, "skipped": 0, "failed": 0}
        self._announced: Optional[tuple] = None
        self._since_poll = 0

    def should_stop(self) -> bool:
        return self.channel.is_cancelled(self.request_id)

    def set_total(self, total: int) -> None:
        self.total = max(0, total)
        self._progress()

    def _progress(self) -> None:
        state = (self.done, self.total)
        if state != self._announced:
            self._announced = state
            self.channel.send({"id": self.request_id, "event": "progress", "done": self.done, "total": self.total})

    def idle(self) -> None:
        """Called for items passed over, so browsing stays answered during long scans."""
        self._since_poll += 1
        if self._since_poll >= PAGE_CHUNK:
            self._since_poll = 0
            self.bridge.serve_waiting()

    def process(self, asset: Any) -> None:
        capture = self.bridge.capture
        capture.reset()
        filename = asset.id
        try:
            filename = self.plan.filename_builder(asset)
            if self.plan.passer(asset):
                self.plan.downloader(self.bridge.icloud, _counter(), asset)
        except Exception as error:  # noqa: BLE001
            capture.errors.append(f"{type(error).__name__}: {error}")
        downloaded, existing, errors = list(capture.downloaded), list(capture.existing), list(capture.errors)
        capture.reset()

        base = {"id": self.request_id, "asset": asset.id, "filename": filename}
        if errors:
            self.counts["failed"] += 1
            self.channel.send({**base, "event": "failed", "reason": errors[0], "paths": downloaded})
        elif downloaded:
            self.counts["downloaded"] += 1
            self.channel.send({**base, "event": "downloaded", "path": downloaded[0], "paths": downloaded})
        elif existing:
            self.counts["skipped"] += 1
            self.channel.send({**base, "event": "skipped", "path": existing[0]})
        else:
            self.counts["failed"] += 1
            self.channel.send({**base, "event": "failed", "reason": "iCloud didn't offer a file for this item."})
        self.done += 1
        self._progress()
        self._since_poll = 0
        self.bridge.serve_waiting()

    def finish(self) -> None:
        self._progress()
        self.channel.send(
            {"id": self.request_id, "event": "done", "cancelled": self.should_stop(), **self.counts}
        )


def _counter() -> Any:
    from icloudpd.counter import Counter

    return Counter(0)


# MARK: - Signing in


def authenticate(channel: Channel, username: str, cookie_directory: str) -> Any:
    """Signs in like icloudpd's core_single_run: its authenticator, the same cookie directory and
    client ID, and a console-style password provider answered over the channel. Returns the
    service and the library icloudpd would download from."""
    from icloudpd import base, cli
    from icloudpd.authentication import authenticator
    from icloudpd.status import StatusExchange

    global_config, user_configs = cli.parse(icloudpd_arguments(username, cookie_directory, None, "month", False))
    user_config = user_configs[0]

    def read_password(_user: str) -> Optional[str]:
        password = channel.read_password()
        if not password:
            raise NeedsSignIn()
        return password

    def needs_user() -> None:
        # Called right before icloudpd would prompt for a two-factor code.
        raise NeedsSignIn()

    icloud = authenticator(
        LOGGER,
        global_config.domain,
        {"console": (read_password, base.dummy_password_writter)},
        global_config.mfa_provider,
        StatusExchange(),
        user_config.username,
        needs_user,
        None,
        user_config.cookie_directory,
        os.environ.get("CLIENT_ID"),
    )
    icloud.response_observer = None

    if user_config.library:
        if user_config.library in icloud.photos.private_libraries:
            library = icloud.photos.private_libraries[user_config.library]
        elif user_config.library in icloud.photos.shared_libraries:
            library = icloud.photos.shared_libraries[user_config.library]
        else:
            raise RequestError("libraryNotFound", f"Unknown library: {user_config.library}")
    else:
        library = icloud.photos
    return icloud, library


def parse_arguments(argv: List[str]) -> Dict[str, str]:
    values: Dict[str, str] = {}
    index = 0
    while index < len(argv):
        flag = argv[index]
        if flag in ("-u", "--username", "--cookie-directory") and index + 1 < len(argv):
            values["cookie_directory" if flag == "--cookie-directory" else "username"] = argv[index + 1]
            index += 2
        else:
            index += 1
    return values


def main(argv: List[str]) -> int:
    # Keep the real stdout for the protocol; anything else printed goes to stderr.
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    logging.basicConfig(
        format="%(asctime)s %(levelname)-8s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stderr,
        level=logging.INFO,
    )
    for handler in logging.getLogger().handlers:
        handler.setLevel(logging.INFO)

    channel = Channel(protocol)
    options = parse_arguments(argv)
    if "username" not in options or "cookie_directory" not in options:
        channel.error(None, "badRequest", "Usage: photo_bridge.py -u APPLE_ID --cookie-directory DIR")
        return 2
    channel.start_reader(sys.stdin)

    from pyicloud_ipd.exceptions import PyiCloud2SARequiredException, PyiCloudFailedMFAException

    patch_icloudpd_for_bridge()
    try:
        icloud, library = authenticate(channel, options["username"], options["cookie_directory"])
    except (NeedsSignIn, PyiCloud2SARequiredException, PyiCloudFailedMFAException):
        channel.send({"event": "signInRequired"})
        return 0
    except RequestError as error:
        channel.error(None, error.kind, str(error))
        return 1
    except Exception as error:  # noqa: BLE001
        channel.error(None, type(error).__name__, str(error))
        return 1

    bridge = Bridge(channel, icloud, library, options["username"], options["cookie_directory"])
    try:
        count = len(library.all)
    except Exception as error:  # noqa: BLE001
        channel.error(None, type(error).__name__, str(error))
        return 1
    channel.send({"event": "ready", "count": count})
    bridge.serve()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
