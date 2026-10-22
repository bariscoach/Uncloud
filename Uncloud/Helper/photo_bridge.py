"""Uncloud's long-running bridge to the iCloud Photos library.

Speaks JSON lines: requests arrive on stdin, responses and events leave on stdout, and
everything else (Python logging, stray prints) goes to stderr. It signs in exactly the way
icloudpd does and downloads with icloudpd's own `download_builder`, so a hand-picked item
lands at the path, with the name, live-photo movie and sidecar, that a full icloudpd run
would give it, and that later run reports it as "already exists".

Usage: python3.13 -I -B photo_bridge.py -u APPLE_ID --cookie-directory DIR

Startup events: {"event":"needPassword"} (answer with one line {"password":"..."}),
{"event":"signInRequired"} (two-factor needed; the bridge exits), {"event":"ready","count":N},
or {"event":"error","kind":...,"message":...}. A {"event":"note","message":...} may come before those; it is
information only (for example, iCloud is still indexing the library), and nothing waits for it.

Requests, each with an "id" that every reply carries. Ranks are positions in icloudpd's walk: rank 0
is the NEWEST item, and an item added to iCloud is inserted at rank 0, shifting every other rank by one.
  {"cmd":"page","offset":O,"limit":L}  -> {"event":"page","offset":O,"items":[...]}
      items in icloudpd's order from rank O: {id, rank, filename, created, added, type, size, bytes, thumbURL}
      (size: the original's bytes; bytes: what a download writes, see stats)
  {"cmd":"count"}                     -> {"event":"count","count":N}
  {"cmd":"albums"}                    -> {"event":"albums","albums":[names]}  (no smart albums)
  {"cmd":"download","mode":"only"|"allExcept","ids":[...],"dest":DIR,"layout":"month"|"album"|"none",
   "album":NAME,"xmp":BOOL,"hints":{id: rank},"startRank":R,"prefetch":N}  (prefetch as for stats)
      layout month: DEST/YYYY/MM/NAME; none: DEST/NAME (icloudpd's --folder-structure none, the
      "All in One Folder" layout); album: DEST/NAME for the items of album NAME.
      startRank (default 0): items at ranks below R are never visited, so a walk pages from rank R
      (in only mode, hints below R are ignored too). In allExcept mode, IDs in "ids" cost no file check.
      stopAt (allExcept only): the walk ends when it reaches that asset, without visiting it, or at the
      end of the library when it isn't there. A walk pages with a small overlap, so an item removed
      above it while it runs doesn't make it miss the item that moves up past a page boundary.
      A finished file is moved to its name without ever replacing a file that appeared there
      meanwhile; that item fails instead (FileAppeared) and the next run names it again.
      -> {"event":"progress","done":D,"total":T} whenever either changes, then per item one of
         {"event":"downloaded","asset","rank","filename","path","paths","files"},
         {"event":"skipped","asset","rank","filename","path","paths","files"},
         {"event":"failed","asset","rank","filename","reason","paths"};
         finally {"event":"done","downloaded":N,"skipped":N,"failed":N,"cancelled":BOOL}.
         In allExcept mode, while a long run of items passed over (IDs in "ids") is walked, also
         {"event":"walked","rank":R} every PAGE_CHUNK items, R being the rank the walk is at; a walk over
         known items then shows its progress without a file check per item.
         Paths are absolute and never shortened. path: the item's first file; paths: the files this
         request wrote (downloaded) or found already there (skipped); files: every file the item has on
         disk now, written or found, plus its XMP sidecar when there is one.
      A throttle (Apple's 503, "Apple iCloud is temporary refusing to serve icloudpd") or a lost
      connection ends the download instead of failing item after item, as it ends an icloudpd run:
         {"event":"error","kind":"PyiCloudServiceUnavailableException"|"PyiCloudConnectionErrorException",
          "message":...,"asset","rank",...counts}, with no "done". The item named isn't finished.
      Cancelling stops between chunks of a file, not only between items, and removes that file's
      partial download. Browsing (page, count, albums) is answered between chunks too, at most every 0.25 s;
      the other requests wait for the download to end.
  {"cmd":"stats","offset":O,"prefetch":N}  walks the library from O (icloudpd's order) a page at a time
      -> {"event":"statsProgress","done":D,"total":T,"bytes":B,"sizes":{id: bytes},"unsized":[ids]}
         per page, where D and B count this request's items so far, sizes holds the page's items and
         unsized the page's items without a size; finally
         {"event":"stats","done":D,"total":T,"bytes":B,"complete":BOOL,"cancelled":BOOL,"timing":{...}}.
         prefetch (optional, default 1 = off, at most 4) fetches that many pages ahead on worker threads.
         A throttle switches the session back to 1 page at a time.
         An item's bytes are what a download writes for it with Uncloud's arguments: the original,
         plus the Live Photo movie when there is one (not XMP sidecars, a few KB each). Browsing
         requests are answered between pages, and the walk stops early (complete false) when a
         download is waiting, so it never holds up an export.
  {"cmd":"delete","mode":"only"|"allExcept","ids":[...],"hints":{id: rank},"batchSize":N,"confirmedCount":C}
      deletes items from iCloud Photos (they move to Recently Deleted, isDeleted = 1). "only" deletes the items
      in ids; "allExcept" deletes every item not in ids. Targets are resolved first, walking the library without
      changing it, then deleted in batches of batchSize (default 100, at most 200), about a second apart.
      Deferred while a download runs, like a download. Missing IDs (no longer in the library) are counted.
      -> {"event":"deleteProgress","phase":"finding"|"deleting","done":D,"total":T} as the work goes on,
         {"event":"deleteTargets","ids":[...]} once the targets are known (so a run can resume as "only"),
         {"event":"deleted","ids":[...]} and {"event":"deleteFailed","failures":[{"id","reason"}]} per batch,
         finally {"event":"deleteDone","deleted":N,"failed":N,"missing":N,"cancelled":BOOL,
         "stopped":null|"throttled"|"error"|"changed","message":...}. A throttle or lost connection ends the run as
         "throttled" with the message; the items it didn't reach aren't deleted and aren't failed. Throttled means
         ACCESS_DENIED, 429, 503 or any 5xx; three batches in a row where every item failed end it as "error".
         confirmedCount is how many items the user confirmed: if the targets resolved are more, nothing is sent
         and the run ends as "changed".
         Cancel and pause act between batches; a batch already sent can't be recalled.
  {"cmd":"restore","mode":"only"|"allExcept","ids":[...],"hints":{id: rank},"batchSize":N,"confirmedCount":C}
      recovers items from iCloud's Recently Deleted album (isDeleted = 0). The same run as delete, with the same
      replies and events (deleteProgress, deleteTargets, deleted, deleteFailed, deleteDone), the same guards and
      stops. The targets are resolved in Recently Deleted: "only" finds the IDs there, "allExcept" walks every item
      there that isn't in ids. A changed album stops the run as "changed" with a message that says nothing was recovered.
  {"cmd":"page","offset":N,"limit":N,"album":"recentlyDeleted"}  and {"cmd":"count","album":"recentlyDeleted"} read
      Recently Deleted instead of the library when album says so. Without album, or with "library", they read the library.
      Any other album is a badRequest. Recently Deleted items carry no days-left value: the bridge doesn't report one.
  {"cmd":"cancel","target":ID}        stops that download (between chunks) or stats walk (after its page).
  {"cmd":"pause","target":ID}         holds that download between chunks or items; browsing requests are
  {"cmd":"resume","target":ID}        still answered while it's held. Neither has a reply.
  {"cmd":"ping"}                      -> {"event":"pong"}, from the request loop itself (between items,
                                      pages and chunks), so a missing pong means the bridge is stuck.
Timing: page, stats, download and delete/restore final events carry "timing": {"queries","items","bytes","seconds"}
(record queries sent to Apple, the bytes of their replies, the items handled, the seconds taken). The same numbers
go to stderr as one line: "timing cmd=page queries=2 items=200 bytes=1043112 seconds=1.31". Older apps ignore it.
Errors: {"id"?, "event":"error","kind":...,"message":...}. Closing stdin or SIGTERM stops the bridge.
Request lines have no length limit (an allExcept list of 100,000 IDs is a few MB).
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

import builtins  # noqa: E402
import copy  # noqa: E402
import datetime  # noqa: E402
import errno  # noqa: E402
import json  # noqa: E402
import logging  # noqa: E402
import os  # noqa: E402
import queue  # noqa: E402
import sys  # noqa: E402
import time  # noqa: E402
import urllib.parse  # noqa: E402
from collections import deque  # noqa: E402
from concurrent.futures import ThreadPoolExecutor  # noqa: E402
from functools import partial  # noqa: E402
from itertools import islice  # noqa: E402
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple  # noqa: E402

# icloudpd's own page size; also the largest window fetched by one request.
PAGE_CHUNK = 100
# Items each walk page shares with the one before, to notice removals made while walking.
WALK_OVERLAP = 5
MAX_PAGE_LIMIT = 500
# Above this share of the library, hint lookups cost more than one pass over it.
HINT_FRACTION = 0.3
# Ranks closer than this are fetched in one window.
HINT_GAP = 25
# A download checks for cancel, pause and pings after each chunk of this many bytes.
DOWNLOAD_CHUNK = 32 * 1024
# Items per CloudKit modify request, the largest allowed, and the pause between two of them.
DELETE_BATCH_SIZE = 100
DELETE_BATCH_MAX = 200
DELETE_PACE = 1.0
# Batches in a row where every item failed before the run gives up.
DELETE_FAILURE_STREAK = 3
DELETE_CHANGED_MESSAGE = (
    "Your iCloud library changed since you confirmed, so nothing was deleted. Review your selection and try again."
)
RESTORE_CHANGED_MESSAGE = (
    "Your iCloud library changed since you confirmed, so nothing was recovered. Review your selection and try again."
)
# What each command does: the album its targets come from (the same names page and count take), the isDeleted
# value its batches set, and the message when the album changed since the user confirmed.
DELETE_ACTIONS = {
    "delete": {"album": "library", "isDeleted": 1, "changed": DELETE_CHANGED_MESSAGE},
    "restore": {"album": "recentlyDeleted", "isDeleted": 0, "changed": RESTORE_CHANGED_MESSAGE},
}
# Browsing answered during one chunk of a download: at most this many requests, and about this many seconds.
BROWSE_REQUESTS_PER_CHUNK = 2
BROWSE_SECONDS_PER_CHUNK = 1.0
# Session errors that mean Apple is limiting requests, whatever class they come as.
THROTTLE_MARKERS = ("ACCESS_DENIED", "429", "503")
# A download answers browsing at most this often (seconds), between chunks of a file, so a large file doesn't hold
# up the library grid. CLOCK is what measures that interval; tests replace it.
SERVE_INTERVAL = 0.25
CLOCK = time.monotonic
# Pages a listing may fetch ahead on worker threads. 1 is off, which is the app's default; the app asks for more
# only when the owner has turned the setting on.
MAX_PREFETCH = 4
# A prefetched page older than this (seconds) is fetched again before use: its download URLs and ranks go stale.
PREFETCH_MAX_AGE = 300.0
# Set when Apple throttles a listing: from then on this session fetches one page at a time.
LISTING_STATE = {"throttled": False}
# The CloudKit fields a listing reads: what describe(), download_bytes() and thumb_url() reach through PhotoAsset
# (the filename, dates, size, type, versions and thumbnail), plus the record names the query loop joins on. Listing
# requests (page, stats) ask only for these, and get the same items; download and delete walks keep icloudpd's
# full list.
LISTING_KEYS = [
    "recordName", "recordType", "masterRef", "assetDate", "addedDate", "isDeleted", "isHidden",
    "adjustmentRenderType", "itemType", "filenameEnc", "resOriginalWidth", "resOriginalHeight",
    "resOriginalRes", "resOriginalFileType", "resOriginalAltRes", "resOriginalAltFileType",
    "resOriginalVidComplRes", "resOriginalVidComplFileType", "resJPEGFullRes", "resJPEGFullFileType",
    "resJPEGMedRes", "resJPEGMedFileType", "resJPEGThumbRes", "resJPEGThumbFileType",
    "resVidMedRes", "resVidMedFileType", "resVidSmallRes", "resVidSmallFileType",
]
# Session files (pyicloud's session and cookie files) are rewritten by every request; this lock keeps two writes apart.
_SESSION_FILE_LOCK = threading.Lock()

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


class DownloadCancelled(Exception):
    """The download was cancelled between two chunks; its partial file is removed. Not an OSError,
    so it passes through icloudpd's download functions untouched."""


class DownloadInterrupted(Exception):
    """A download held by a pause couldn't be picked up where it stopped."""


class DeleteStopped(Exception):
    """A delete run that ends early: `kind` is "throttled", "changed" or "error", with the message for the app."""

    def __init__(self, kind: str, message: str):
        super().__init__(message)
        self.kind = kind
        self.message = message


def is_throttle_error(error: BaseException) -> bool:
    text = f"{type(error).__name__} {error}"
    return any(marker in text for marker in THROTTLE_MARKERS)


def is_real_throttle(error: BaseException) -> bool:
    """Apple refusing to serve (a 503, a 429 or ACCESS_DENIED), and nothing else: a lost connection doesn't count."""
    return is_throttle_error(error) or any(
        cls.__name__ == "PyiCloudServiceUnavailableException" for cls in type(error).__mro__
    )


class FileAppeared(Exception):
    """A file appeared at the download's path after icloudpd chose the name: it's never overwritten.
    Not an OSError, so icloudpd doesn't report it as a full disk; the item fails and the next run
    names it again, beside the file that's there now."""


# Exceptions that end an icloudpd run (`run_with_configs` returns 1 on them), so they end a download
# too, instead of failing every item that follows: Apple's throttle (HTTP 503, "Apple iCloud is
# temporary refusing to serve icloudpd") and a lost connection. Named, not imported, so tests and
# the module load without pyicloud_ipd's import order mattering.
RUN_ENDING_ERRORS = ("PyiCloudServiceUnavailableException", "PyiCloudConnectionErrorException")


def is_run_ending(error: BaseException) -> bool:
    return any(cls.__name__ in RUN_ENDING_ERRORS for cls in type(error).__mro__)


class DownloadStopped(Exception):
    """A run-ending error during a download, with the item it stopped at."""

    def __init__(self, error: BaseException, asset_id: Optional[str], rank: Optional[int]):
        super().__init__(str(error))
        self.kind = next(cls.__name__ for cls in type(error).__mro__ if cls.__name__ in RUN_ENDING_ERRORS)
        self.asset_id = asset_id
        self.rank = rank


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
        self._paused: set = set()
        self._pings: List[Any] = []
        # Set whenever a line arrives, so a held download notices pause, resume and requests at once.
        self._wake = threading.Event()
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
        command = message.get("cmd")
        try:
            if command == "cancel":
                with self._cancel_lock:
                    self._cancelled.add(message.get("target"))
                return
            if command in ("pause", "resume"):
                with self._cancel_lock:
                    if command == "pause":
                        self._paused.add(message.get("target"))
                    else:
                        self._paused.discard(message.get("target"))
                return
            if command == "ping":
                # Answered by the request loop at its next check, or from the queue when it's idle.
                with self._cancel_lock:
                    self._pings.append(message.get("id"))
            self._requests.put(message)
        finally:
            self._wake.set()

    def close(self) -> None:
        if not self.closed.is_set():
            self.closed.set()
            self._requests.put(None)
            self._passwords.put(None)
            self._wake.set()

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

    def is_paused(self, request_id: Any) -> bool:
        with self._cancel_lock:
            return request_id in self._paused

    def forget(self, request_id: Any) -> None:
        """Drops a finished request's cancel and pause state."""
        with self._cancel_lock:
            self._cancelled.discard(request_id)
            self._paused.discard(request_id)

    def answer_pings(self) -> None:
        """Answers the pings that arrived since the last call."""
        with self._cancel_lock:
            pings, self._pings = self._pings, []
        for ping_id in pings:
            self.send({"id": ping_id, "event": "pong"})

    def wait_for_input(self, timeout: float) -> None:
        """Waits up to `timeout` seconds for the next input line."""
        self._wake.wait(timeout)
        self._wake.clear()


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
        # Both, in the order icloudpd reported them: the item's main file first.
        self.files: List[str] = []
        self.errors: List[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        args = record.args if isinstance(record.args, tuple) else ()
        if record.msg == "Downloaded %s" and args:
            self.downloaded.append(str(args[0]))
            self.files.append(str(args[0]))
        elif record.msg == "%s already exists" and args:
            self.existing.append(str(args[0]))
            self.files.append(str(args[0]))
        elif record.levelno >= logging.ERROR and record.msg not in _TRANSIENT_ERRORS:
            try:
                self.errors.append(record.getMessage())
            except Exception:  # noqa: BLE001
                self.errors.append(str(record.msg))


def patch_icloudpd_for_bridge(notify: Optional[Callable[[str], None]] = None) -> None:
    """icloudpd shortens paths in its log lines; the bridge reads full paths from them."""
    from icloudpd import base

    base.truncate_middle = lambda text, _length: text
    patch_downloads_for_bridge()
    patch_indexing_state_for_bridge(notify)
    patch_listing_keys_for_bridge()
    patch_timing_for_bridge()
    guard_session_files_for_bridge()


def patch_listing_keys_for_bridge() -> None:
    """A query for an album whose `_uncloud_keys` is set asks only for those fields (see LISTING_KEYS)."""
    from pyicloud_ipd.services import photos

    original = photos.PhotoAlbum._list_query_gen
    if getattr(original, "_uncloud", False):
        return

    def _list_query_gen(self: Any, offset: int, list_type: str, query_filter: Any = None) -> Any:
        query = original(self, offset, list_type, query_filter)
        keys = getattr(self, "_uncloud_keys", None)
        if keys is not None:
            query["desiredKeys"] = list(keys)
        return query

    _list_query_gen._uncloud = True  # type: ignore[attr-defined]
    photos.PhotoAlbum._list_query_gen = _list_query_gen


def patch_timing_for_bridge() -> None:
    """Every record query goes through here, so the request on top of the timer stack counts it (see RequestTimer)."""
    from pyicloud_ipd.services import photos

    original = photos.PhotoAlbum.photos_request
    if getattr(original, "_uncloud", False):
        return

    def photos_request(self: Any) -> Any:
        response = original(self)
        note_query(self, response)
        return response

    photos_request._uncloud = True  # type: ignore[attr-defined]
    photos.PhotoAlbum.photos_request = photos_request


class _GuardedWrite:
    """A file opened for writing that holds the session-files lock until it's closed."""

    def __init__(self, path: Any, mode: str, args: tuple, kwargs: dict) -> None:
        _SESSION_FILE_LOCK.acquire()
        try:
            self._file = builtins.open(path, mode, *args, **kwargs)
        except BaseException:
            _SESSION_FILE_LOCK.release()
            raise

    def __enter__(self) -> Any:
        return self._file

    def __exit__(self, *exc_info: Any) -> bool:
        try:
            self._file.close()
        finally:
            _SESSION_FILE_LOCK.release()
        return False

    def __getattr__(self, name: str) -> Any:
        return getattr(self._file, name)


def _guarded_open(path: Any, mode: str = "r", *args: Any, **kwargs: Any) -> Any:
    if any(flag in mode for flag in "wax+"):
        return _GuardedWrite(path, mode, args, kwargs)
    return builtins.open(path, mode, *args, **kwargs)


def guard_session_files_for_bridge() -> None:
    """Listings run on worker threads (see PageReader), and each request rewrites pyicloud's session and cookie
    files. Writes to them are serialized: pyicloud's session module opens its files through `_guarded_open`, and
    the cookie jar's save runs under the same lock. Reads, and the HTTP requests themselves, are not serialized."""
    import http.cookiejar

    from pyicloud_ipd import session as pyicloud_session

    pyicloud_session.open = _guarded_open  # type: ignore[attr-defined]
    for cls in (http.cookiejar.FileCookieJar, http.cookiejar.LWPCookieJar, http.cookiejar.MozillaCookieJar):
        original = cls.__dict__.get("save")
        if original is None or getattr(original, "_uncloud", False):
            continue

        def save(self: Any, *args: Any, _original: Any = original, **kwargs: Any) -> Any:
            # The jar's own lock too: extract_cookies adds cookies under it while another listing saves.
            with _SESSION_FILE_LOCK, self._cookies_lock:
                return _original(self, *args, **kwargs)

        save._uncloud = True  # type: ignore[attr-defined]
        cls.save = save  # type: ignore[method-assign]

    # session_data is updated by every response (outside any file lock) while the session file is dumped. The dump
    # takes a copy first, so it never iterates a dict that another thread is changing.
    if not isinstance(getattr(pyicloud_session, "json", None), _SnapshotJson):
        pyicloud_session.json = _SnapshotJson(pyicloud_session.json)  # type: ignore[attr-defined]


class _SnapshotJson:
    """pyicloud's session module's `json`, with `dump` writing a copy of a dict (see guard_session_files_for_bridge)."""

    def __init__(self, module: Any) -> None:
        self._module = module

    def dump(self, obj: Any, fp: Any, *args: Any, **kwargs: Any) -> Any:
        if isinstance(obj, dict):
            obj = dict(obj)
        return self._module.dump(obj, fp, *args, **kwargs)

    def __getattr__(self, name: str) -> Any:
        return getattr(self._module, name)


INDEXING_NOTE = "iCloud is still indexing this library; continuing. Very recent changes may appear in a later export."
_indexing_notice: Dict[str, Any] = {"notify": None, "sent": False}


def patch_indexing_state_for_bridge(notify: Optional[Callable[[str], None]] = None) -> None:
    """Apple answers CheckIndexingState with RUNNING while it indexes a library that can still be read. pyicloud_ipd
    raises then, and the library would be dropped. PhotoLibrary sets all its attributes before that check, so the
    library is usable: keep it, log a warning, and send `notify` the note once. Other errors are still raised."""
    from pyicloud_ipd.exceptions import PyiCloudServiceNotActivatedException
    from pyicloud_ipd.services import photos

    _indexing_notice["notify"] = notify
    original = photos.PhotoLibrary.__init__
    if getattr(original, "_uncloud", False):
        return

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        try:
            original(self, *args, **kwargs)
        except PyiCloudServiceNotActivatedException as error:
            if "not finished indexing" not in str(error):
                raise
            LOGGER.warning(INDEXING_NOTE)
            if not _indexing_notice["sent"] and _indexing_notice["notify"] is not None:
                _indexing_notice["sent"] = True
                _indexing_notice["notify"](INDEXING_NOTE)

    __init__._uncloud = True  # type: ignore[attr-defined]
    photos.PhotoLibrary.__init__ = __init__


def patch_downloads_for_bridge() -> None:
    """Makes icloudpd's file download stop between chunks when its request is cancelled (removing
    the partial file) or hold while it's paused, through the run that `_DownloadRun.process` sets."""
    from icloudpd import download
    from pyicloud_ipd.services import photos

    original = photos.download_asset
    if getattr(original, "_uncloud", False):
        return

    def download_asset(session: Any, url: str, start: int = 0) -> Any:
        response = original(session, url, start)
        try:
            # Where to ask again with a Range after a pause closed the connection.
            response._uncloud_source = (session, url)
        except AttributeError:
            pass
        return response

    download_asset._uncloud = True  # type: ignore[attr-defined]
    photos.download_asset = download_asset
    download.download_response_to_path = write_response


_ACTIVE_RUN: Optional["_DownloadRun"] = None


def _remove(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def write_response(
    response: Any, temp_download_path: str, append_mode: bool, download_path: str, created_date: Any
) -> bool:
    """icloudpd's `download_response_to_path`, checking the active run after every chunk."""
    from icloudpd import download
    from pyicloud_ipd.services import photos

    run = _ACTIVE_RUN
    try:
        with open(temp_download_path, "ab" if append_mode else "wb") as file_obj:
            while True:
                held = False
                begin = os.fstat(file_obj.fileno()).st_size
                length = _content_length(response)
                for chunk in response.iter_content(chunk_size=DOWNLOAD_CHUNK):
                    if chunk:
                        file_obj.write(chunk)
                    if run is None:
                        continue
                    state = run.between_chunks()
                    if state == "cancel":
                        raise DownloadCancelled()
                    if state == "pause":
                        held = True
                        break
                if not held or run is None:
                    break
                file_obj.flush()
                if length is not None and os.fstat(file_obj.fileno()).st_size - begin >= length:
                    # A pause on the last chunk: the whole response is written, so there's nothing to ask for.
                    break
                # Don't hold a connection open for the length of a pause: ask again for the rest.
                close = getattr(response, "close", None)
                if close is not None:
                    close()
                if not run.hold():
                    raise DownloadCancelled()
                source = getattr(response, "_uncloud_source", None)
                if source is None:
                    raise DownloadInterrupted("The download couldn't continue after the pause.")
                session, url = source
                response = photos.download_asset(session, url, os.fstat(file_obj.fileno()).st_size)
                if not getattr(response, "ok", False):
                    raise DownloadInterrupted("iCloud didn't continue the download after the pause.")
                if getattr(response, "status_code", 206) == 200:
                    # The server ignored the Range and sends the whole file: start the file again.
                    file_obj.seek(0)
                    file_obj.truncate()
    except DownloadCancelled:
        _remove(temp_download_path)
        raise
    if not move_into_place(temp_download_path, download_path):
        _remove(temp_download_path)
        raise FileAppeared(f"{download_path} appeared while it was downloading; it was left as it is.")
    download.update_mtime(created_date, download_path)
    return True


_RENAME_EXCL = 0x00000004


def _renamex_excl(source: str, target: str) -> Optional[bool]:
    """macOS renamex_np(RENAME_EXCL): True when moved, False when the target exists, None when the
    call or the file system doesn't support it."""
    try:
        import ctypes

        libc = ctypes.CDLL(None, use_errno=True)
        renamex = libc.renamex_np
    except (OSError, AttributeError, ImportError):
        return None
    renamex.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex.restype = ctypes.c_int
    if renamex(os.fsencode(source), os.fsencode(target), _RENAME_EXCL) == 0:
        return True
    if ctypes.get_errno() == errno.EEXIST:
        return False
    return None


def move_into_place(temp_path: str, path: str) -> bool:
    """Moves a finished download to its name without ever replacing a file there: False (and the
    download left at `temp_path`) when something already has the name. Each way used refuses an
    existing name atomically: renamex_np(RENAME_EXCL), a hard link, or an exclusive create."""
    moved = _renamex_excl(temp_path, path)
    if moved is not None:
        return moved
    try:
        os.link(temp_path, path)
    except FileExistsError:
        return False
    except OSError:
        # No hard links on this file system (FAT32, some network shares): copy into a file created only
        # if nothing has the name, so a file that appears meanwhile is never replaced.
        return _copy_exclusive(temp_path, path)
    _remove(temp_path)
    return True


def _copy_exclusive(temp_path: str, path: str) -> bool:
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    except FileExistsError:
        return False
    try:
        with os.fdopen(descriptor, "wb") as target, open(temp_path, "rb") as source:
            while True:
                chunk = source.read(DOWNLOAD_CHUNK)
                if not chunk:
                    break
                target.write(chunk)
    except BaseException:
        _remove(path)
        raise
    _remove(temp_path)
    return True


def _content_length(response: Any) -> Optional[int]:
    """The length the server said the response body has, or None when it didn't say."""
    try:
        return int(response.headers["Content-Length"])
    except (AttributeError, KeyError, TypeError, ValueError):
        return None


# MARK: - Library access


def fetch_assets(album: Any, offset: int, limit: int, lean: bool = False) -> List[Any]:
    """Items `offset..<offset+limit` of an album, in icloudpd's order, with its own paging. `lean` asks for
    LISTING_KEYS only (a listing); otherwise the query has icloudpd's full list of fields."""
    if limit <= 0:
        return []
    view = copy.copy(album)
    view.offset = max(0, offset)
    view.page_size = min(limit, PAGE_CHUNK)
    if lean:
        view._uncloud_keys = LISTING_KEYS
    return list(islice(view.photos, limit))


def listing_depth(requested: int) -> int:
    """How many pages a listing fetches ahead: `requested` clamped to 1..MAX_PREFETCH, and 1 once Apple has throttled."""
    if LISTING_STATE["throttled"]:
        return 1
    return min(max(requested, 1), MAX_PREFETCH)


def parse_prefetch(request: Dict[str, Any]) -> int:
    """The request's "prefetch" (pages ahead, default 1 = off)."""
    value = request.get("prefetch", 1)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise RequestError("badRequest", "prefetch must be a number, 1 or more.")
    return min(value, MAX_PREFETCH)


class PageReader:
    """Pages of an album for a listing, fetched one at a time, or up to `depth` ahead on worker threads (R11).

    Every page is a query of its own (the startRank filter makes them independent), so they can come back in
    any order. The walk or stats pass says which pages come next (`ahead`); a page that's asked for and wasn't
    predicted is fetched in line, and the predictions that didn't come true are dropped. A prefetched page older
    than `max_age` seconds when it's used is fetched again: download URLs and ranks go stale. A throttle, or any
    run-ending error, is raised where the page is asked for, and the listing has to stop there. Queries made by a
    prefetch count for the request that submitted it (see note_query)."""

    def __init__(self, album: Any, depth: int = 1, lean: bool = False, max_age: Optional[float] = None) -> None:
        self._album = album
        self._depth = depth
        self._lean = lean
        self._max_age = PREFETCH_MAX_AGE if max_age is None else max_age
        self._pool: Optional[ThreadPoolExecutor] = None
        self._pending: Dict[tuple, Any] = {}

    def get(self, offset: int, limit: int) -> List[Any]:
        future = self._pending.pop((offset, limit), None)
        if future is None:
            self.drop()
            return self._fetch(offset, limit)
        fetched_at, page = future.result()
        if time.monotonic() - fetched_at >= self._max_age:
            return self._fetch(offset, limit)
        return page

    def ahead(self, keys: Iterable[tuple]) -> None:
        """Starts fetching the pages (offset, limit) in `keys`, while there's room for `depth` of them."""
        if self._depth <= 1:
            return
        for key in keys:
            if key in self._pending or len(self._pending) >= self._depth:
                continue
            if self._pool is None:
                self._pool = ThreadPoolExecutor(max_workers=self._depth, thread_name_prefix="photo_bridge_pages")
            self._pending[key] = self._pool.submit(self._fetch_for_pool, key, current_timer())

    def drop(self) -> None:
        pending, self._pending = self._pending, {}
        for future in pending.values():
            future.cancel()

    def close(self) -> None:
        self.drop()
        if self._pool is not None:
            self._pool.shutdown(wait=False, cancel_futures=True)
            self._pool = None

    def _fetch_for_pool(self, key: tuple, timer: Optional["RequestTimer"]) -> Tuple[float, List[Any]]:
        _QUERY_TIMER.bound, _QUERY_TIMER.timer = True, timer
        try:
            page = self._fetch(*key)
        finally:
            _QUERY_TIMER.bound, _QUERY_TIMER.timer = False, None
        return time.monotonic(), page

    def _fetch(self, offset: int, limit: int) -> List[Any]:
        try:
            return fetch_assets(self._album, offset, limit, lean=self._lean)
        except Exception as error:  # noqa: BLE001
            if is_real_throttle(error):
                LISTING_STATE["throttled"] = True
            raise


def walk(
    album: Any, start: int = 0, depth: int = 1, eager: bool = True, ahead_allowed: Optional[Callable[[], bool]] = None,
) -> Iterable[tuple]:
    """(rank, asset) for every item of an album from rank `start` on, PAGE_CHUNK items per query.

    CloudKit pages by offset, so an item removed above the walk's position while it runs would move
    the item just below a page boundary up into the page already fetched, and a plain offset walk
    would never see it. Each page after the first therefore starts WALK_OVERLAP items early and
    lines up on the last items already visited: if they moved up by more than that, it looks further
    back. Items moved down by an addition show up twice and are passed over the second time. Ranks
    are the items' ranks when their page was fetched. Pages a copy, so the album itself (albums are
    cached) keeps its offset and can be walked again.

    `depth` pages are fetched ahead while the caller handles the current one (see PageReader). The next
    page starts WALK_OVERLAP items before the end of this one, so that is where the predictions point."""
    start = max(0, start)
    offset = start
    seen: set = set()
    recent: List[str] = []
    depth = listing_depth(depth)
    pages = PageReader(album, depth)
    try:
        while True:
            back = WALK_OVERLAP if recent else 0
            while True:
                low = max(start, offset - back)
                limit = PAGE_CHUNK if back <= WALK_OVERLAP else (offset - low) + PAGE_CHUNK
                page = pages.get(low, limit)
                position = {asset.id: index for index, asset in enumerate(page)}
                hit = next((position[i] for i in reversed(recent) if i in position), None)
                if not recent or hit is not None or low == start:
                    break
                # More than `back` items above were removed (or the last ones visited were): look further back.
                pages.drop()
                back *= 4
            first = 0 if hit is None else hit + 1
            # A download (eager False) prefetches only while the walk is passing over known items: the pages it
            # would skip are cheap to fetch ahead, and the items it downloads aren't held up by queries.
            if len(page) == PAGE_CHUNK and (eager or ahead_allowed is None or ahead_allowed()):
                step = PAGE_CHUNK - WALK_OVERLAP
                pages.ahead((low + step * ahead, PAGE_CHUNK) for ahead in range(1, depth + 1))
            visited: List[str] = []
            for index in range(first, len(page)):
                asset = page[index]
                if asset.id in seen:
                    continue
                seen.add(asset.id)
                visited.append(asset.id)
                yield low + index, asset
            if len(page) < limit:
                return
            recent = visited or recent
            offset = low + len(page)
    finally:
        pages.close()


def thumb_url(asset: Any) -> Optional[str]:
    for record in (asset._asset_record, asset._master_record):
        entry = record.get("fields", {}).get("resJPEGThumbRes")
        if entry:
            url = entry.get("value", {}).get("downloadURL")
            if url:
                return str(url)
    return None


def download_bytes(asset: Any) -> Optional[int]:
    """The bytes icloudpd writes for an item with Uncloud's arguments (`--size original`, Live Photo
    movies at their original size): the original, plus the Live Photo movie when the record has
    one. None when the record has no size at all."""
    from pyicloud_ipd.version_size import AssetVersionSize, LivePhotoVersionSize

    try:
        versions = asset.versions
    except Exception:  # noqa: BLE001
        versions = {}
    original = versions.get(AssetVersionSize.ORIGINAL)
    try:
        total = int(original.size) if original is not None else int(asset.size)
    except (KeyError, TypeError, ValueError):
        return None
    live = versions.get(LivePhotoVersionSize.ORIGINAL)
    if live is not None:
        try:
            total += int(live.size)
        except (TypeError, ValueError):
            pass
    return total


def utc_timestamp(moment: Any) -> Optional[str]:
    """An ISO 8601 UTC string for a datetime, or None when it can't be converted."""
    try:
        if moment.tzinfo is None:
            moment = moment.astimezone()
        return moment.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, OSError, OverflowError):
        return None


def describe(asset: Any) -> Dict[str, Any]:
    from pyicloud_ipd.item_type import AssetItemType

    try:
        created: Optional[str] = utc_timestamp(asset.asset_date)
    except (KeyError, TypeError, ValueError, OSError, OverflowError):
        created = None
    # The date the item was added to the library: the order icloudpd's walk uses, so new items are the ones
    # added after the last export. Nil when the record doesn't say.
    try:
        added: Optional[str] = utc_timestamp(asset.added_date)
    except (KeyError, TypeError, ValueError, OSError, OverflowError):
        added = None
    try:
        size: Optional[int] = int(asset.size)
    except (KeyError, TypeError, ValueError):
        size = None
    return {
        "id": asset.id,
        "filename": asset.filename,
        "created": created,
        "added": added,
        "type": "movie" if asset.item_type == AssetItemType.MOVIE else "image",
        "size": size,
        "bytes": download_bytes(asset),
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


# MARK: - Timing

# The requests whose work is timed and logged (R9).
TIMED_COMMANDS = ("page", "count", "albums", "stats", "download", "delete", "restore")
_TIMERS: List["RequestTimer"] = []
_TIMERS_LOCK = threading.Lock()
_FIRST_QUERY_LOGGED = {"done": False}


class RequestTimer:
    """What one request costs: the record queries it sends to Apple, the bytes of their replies, and the seconds it
    takes. A query counts for the request on top of the timer stack, so a browsing request answered during a
    download counts for itself, and the download's own queries count for the download."""

    def __init__(self, command: str) -> None:
        self.command = command
        self.queries = 0
        self.bytes = 0
        self.started = time.monotonic()
        self.result: Optional[Dict[str, Any]] = None
        self._lock = threading.Lock()

    def note_query(self, size: int) -> None:
        with self._lock:
            self.queries += 1
            self.bytes += size

    def finish(self, items: int = 0) -> Dict[str, Any]:
        """The timing for the request. The first call logs the timing line; later calls return the same numbers."""
        with self._lock:
            if self.result is None:
                seconds = time.monotonic() - self.started
                self.result = {
                    "queries": self.queries, "items": items, "bytes": self.bytes, "seconds": round(seconds, 3),
                }
                LOGGER.info(
                    "timing cmd=%s queries=%d items=%d bytes=%d seconds=%.2f",
                    self.command, self.queries, items, self.bytes, seconds,
                )
            return self.result


def begin_timer(command: Any) -> Optional[RequestTimer]:
    if command not in TIMED_COMMANDS:
        return None
    timer = RequestTimer(command)
    with _TIMERS_LOCK:
        _TIMERS.append(timer)
    return timer


def end_timer(timer: Optional[RequestTimer]) -> None:
    if timer is None:
        return
    with _TIMERS_LOCK:
        _TIMERS[:] = [entry for entry in _TIMERS if entry is not timer]


def timing_field(timer: Optional[RequestTimer], items: int) -> Dict[str, Any]:
    """The `timing` key for a final event, or nothing when the request isn't timed."""
    if timer is None:
        return {}
    return {"timing": timer.finish(items)}


def _response_size(response: Any) -> int:
    try:
        return len(response.content)
    except Exception:  # noqa: BLE001
        return 0


# A prefetch worker's queries count for the request that submitted them (PageReader.ahead), not for whatever
# request is on top of the stack when the query happens to run.
_QUERY_TIMER = threading.local()


def current_timer() -> Optional[RequestTimer]:
    with _TIMERS_LOCK:
        return _TIMERS[-1] if _TIMERS else None


def note_query(album: Any, response: Any) -> None:
    """Counts one record query for the request it belongs to (the one on top of the timer stack, or the one that
    submitted a prefetch). The first query of the session also logs its resultsLimit against the records Apple
    returned, so a short answer shows up in the log."""
    if getattr(_QUERY_TIMER, "bound", False):
        timer = _QUERY_TIMER.timer
    else:
        timer = current_timer()
    if timer is not None:
        timer.note_query(_response_size(response))
    if not _FIRST_QUERY_LOGGED["done"]:
        _FIRST_QUERY_LOGGED["done"] = True
        try:
            records = len(response.json().get("records", []))
        except Exception:  # noqa: BLE001
            records = -1
        LOGGER.info("query resultsLimit=%d records=%d", int(album.page_size) * 2, records)


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
        long_request = command in ("download", "stats", "delete", "restore")
        # A long request that is deferred does no work now, so it's timed when it runs.
        timer = None if downloading and long_request else begin_timer(command)
        try:
            if command == "page":
                offset = int(request.get("offset", 0))
                limit = max(0, min(int(request.get("limit", 200)), MAX_PAGE_LIMIT))
                album = self._album(request.get("album"))
                items = [
                    {**describe(a), "rank": max(0, offset) + i}
                    for i, a in enumerate(fetch_assets(album, offset, limit, lean=True))
                ]
                reply = {"id": request_id, "event": "page", "offset": offset, "items": items}
                reply.update(timing_field(timer, len(items)))
                self.channel.send(reply)
            elif command == "count":
                album = self._album(request.get("album"))
                self.channel.send({"id": request_id, "event": "count", "count": len(album)})
            elif command == "ping":
                self.channel.answer_pings()
            elif command == "albums":
                from pyicloud_ipd.services.photos import PhotoLibrary

                names = [n for n in self.albums(refresh=True) if n not in PhotoLibrary.SMART_FOLDERS]
                self.channel.send({"id": request_id, "event": "albums", "albums": names})
            elif long_request:
                if downloading:
                    self._deferred.append(request)
                elif command == "download":
                    self.download(request, timer)
                elif command == "stats":
                    self.stats(request, timer)
                else:
                    self.delete(request, action=command, timer=timer)
            else:
                raise RequestError("badRequest", f"Unknown command {command!r}.")
        except RequestError as error:
            self.channel.error(request_id, error.kind, str(error))
        except Exception as error:  # noqa: BLE001
            self.channel.error(request_id, type(error).__name__, str(error))
        finally:
            if timer is not None:
                # Already finished, with its items, when the request sent its final event; this logs the rest.
                timer.finish()
                end_timer(timer)

    def serve_waiting(self, limit: Optional[int] = None, seconds: Optional[float] = None) -> None:
        """Answers browsing requests that arrived during a download, between its items. With `limit` and `seconds`,
        it answers at most that many requests and stops after about that long; the rest wait in the queue."""
        self.channel.answer_pings()
        started = time.monotonic()
        served = 0
        while True:
            if limit is not None and served >= limit:
                return
            if seconds is not None and time.monotonic() - started >= seconds:
                return
            request = self.channel.poll_request()
            if request is None:
                return
            self.handle(request, downloading=True)
            served += 1

    def _album(self, name: Any) -> Any:
        """The album a request names: Recently Deleted for "recentlyDeleted", the library otherwise."""
        if name is None or name == "library":
            return self.library.all
        if name == "recentlyDeleted":
            return self.library.recently_deleted
        raise RequestError("badRequest", "album must be library or recentlyDeleted.")

    def albums(self, refresh: bool = False) -> Dict[str, Any]:
        if self._albums is None or refresh:
            self._albums = dict(self.library.albums)
        return self._albums

    # Sizes

    def stats(self, request: Dict[str, Any], timer: Optional[RequestTimer] = None) -> None:
        """Streams each item's download size, a page at a time, from `offset` to the end."""
        request_id = request.get("id")
        try:
            offset = max(0, int(request.get("offset") or 0))
        except (TypeError, ValueError):
            raise RequestError("badRequest", "offset must be a number.")
        depth = listing_depth(parse_prefetch(request))
        album = self.library.all
        total = len(album)
        pages = PageReader(album, depth, lean=True)
        done = 0
        total_bytes = 0
        sizes: Dict[str, int] = {}
        unsized: List[str] = []
        in_page = 0
        complete = True
        cancelled = False

        def report() -> None:
            self.channel.send({
                "id": request_id, "event": "statsProgress", "done": done, "total": total,
                "bytes": total_bytes, "sizes": sizes, "unsized": unsized,
            })

        try:
            position = offset
            walking = True
            while walking:
                page = pages.get(position, PAGE_CHUNK)
                if not page:
                    break
                if len(page) == PAGE_CHUNK:
                    pages.ahead((position + PAGE_CHUNK * ahead, PAGE_CHUNK) for ahead in range(1, depth + 1))
                for asset in page:
                    size = download_bytes(asset)
                    if size is not None:
                        sizes[asset.id] = size
                        total_bytes += size
                    else:
                        unsized.append(asset.id)
                    done += 1
                    in_page += 1
                    if in_page < PAGE_CHUNK:
                        continue
                    report()
                    sizes = {}
                    unsized = []
                    in_page = 0
                    if self.channel.is_cancelled(request_id):
                        cancelled, complete, walking = True, False, False
                        break
                    # Browsing goes first; a download that arrived meanwhile ends the walk.
                    self.serve_waiting()
                    if self._deferred or self.channel.is_cancelled(request_id):
                        cancelled = self.channel.is_cancelled(request_id)
                        complete, walking = False, False
                        break
                if not walking:
                    break
                position += len(page)
                if len(page) < PAGE_CHUNK:
                    break
        finally:
            pages.close()
        if in_page or done == 0:
            report()
        final = {
            "id": request_id, "event": "stats", "done": done, "total": total, "bytes": total_bytes,
            "complete": complete, "cancelled": cancelled,
        }
        final.update(timing_field(timer, done))
        self.channel.send(final)

    # Downloading

    def download(self, request: Dict[str, Any], timer: Optional[RequestTimer] = None) -> None:
        request_id = request.get("id")
        mode = request.get("mode")
        if mode not in ("only", "allExcept"):
            raise RequestError("badRequest", "mode must be only or allExcept.")
        layout = request.get("layout", "month")
        if layout not in ("month", "album", "none"):
            raise RequestError("badRequest", "layout must be month, album or none.")
        destination = request.get("dest")
        if not isinstance(destination, str) or not destination:
            raise RequestError("badRequest", "dest is required.")
        start_rank = request.get("startRank") or 0
        if not isinstance(start_rank, int) or isinstance(start_rank, bool) or start_rank < 0:
            raise RequestError("badRequest", "startRank must be a rank, 0 or more.")
        # Only the set is kept: the request's list can be a few MB.
        ids = set(str(i) for i in (request.pop("ids", None) or []))
        hints = request.get("hints") or {}
        stop_at = request.get("stopAt")
        if stop_at is not None and (mode != "allExcept" or not isinstance(stop_at, str)):
            raise RequestError("badRequest", "stopAt is an asset ID, for allExcept downloads.")
        depth = listing_depth(parse_prefetch(request))

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
        run = _DownloadRun(self, request_id, plan, timer)
        try:
            self._download(run, album, mode, layout, ids, hints, start_rank, stop_at, depth)
        except DownloadStopped as stopped:
            run.stop(stopped)
            return
        except Exception as error:  # noqa: BLE001
            # Paging can hit the throttle too (it's a CloudKit query).
            if not is_run_ending(error):
                self.channel.forget(request_id)
                raise
            run.stop(DownloadStopped(error, None, None))
            return
        run.finish()

    def _download(
        self, run: "_DownloadRun", album: Any, mode: str, layout: str, ids: set, hints: Dict[str, Any],
        start_rank: int, stop_at: Optional[str] = None, depth: int = 1,
    ) -> None:
        if mode == "allExcept":
            run.set_total(max(0, len(album) - start_rank))
            for rank, asset in walk(album, start_rank, depth, eager=False, ahead_allowed=run.mostly_idle):
                if run.should_stop():
                    break
                if stop_at is not None and asset.id == stop_at:
                    run.set_total(run.done)
                    break
                if asset.id in ids:
                    run.set_total(run.total - 1)
                    run.idle(rank)
                    continue
                run.process(asset, rank)
            return
        remaining = set(ids)
        if layout != "album":
            run.set_total(len(remaining))
            for rank, asset in self._hinted(album, remaining, hints, run, start_rank):
                if run.should_stop():
                    break
                remaining.discard(asset.id)
                run.process(asset, rank)
        else:
            # Membership is only known by walking the album; the total grows with each match.
            run.set_total(0)
        if remaining and not run.should_stop():
            for rank, asset in walk(album, start_rank, depth, eager=False, ahead_allowed=run.mostly_idle):
                if run.should_stop():
                    break
                if asset.id in remaining:
                    remaining.discard(asset.id)
                    if layout == "album":
                        run.set_total(run.total + 1)
                    run.process(asset, rank)
                    if not remaining:
                        break
                else:
                    run.idle()
        if layout != "album" and not run.should_stop() and remaining:
            # Items deleted from iCloud since they were selected (or, with startRank, ranked below it).
            run.set_total(run.total - len(remaining))

    def _hinted(
        self, album: Any, remaining: set, hints: Dict[str, Any], run: "_RequestRun", start_rank: int = 0
    ) -> Iterable[tuple]:
        ranks = []
        for asset_id, rank in hints.items():
            if asset_id in remaining and isinstance(rank, int) and rank >= start_rank:
                ranks.append(rank)
        if not ranks:
            return
        try:
            library_size = len(album)
        except Exception as error:  # noqa: BLE001
            if is_run_ending(error):
                raise
            return
        if len(ranks) > library_size * HINT_FRACTION:
            return
        for window in hint_windows(ranks):
            if run.should_stop():
                return
            for offset, asset in enumerate(fetch_assets(album, window.start, len(window))):
                if asset.id in remaining:
                    yield window.start + offset, asset


    # Deleting

    def delete(self, request: Dict[str, Any], action: str = "delete", timer: Optional[RequestTimer] = None) -> None:
        """Deletes items from iCloud Photos (action "delete"), or recovers them from Recently Deleted ("restore").
        Resolves every target first (never changing the album while walking, which would shift the offsets), then
        sends CloudKit modify requests of `batchSize` items. See the protocol notes."""
        spec = DELETE_ACTIONS[action]
        request_id = request.get("id")
        mode = request.get("mode")
        if mode not in ("only", "allExcept"):
            raise RequestError("badRequest", "mode must be only or allExcept.")
        batch_size = request.get("batchSize", DELETE_BATCH_SIZE)
        if not isinstance(batch_size, int) or isinstance(batch_size, bool) or not 1 <= batch_size <= DELETE_BATCH_MAX:
            raise RequestError("badRequest", f"batchSize must be from 1 to {DELETE_BATCH_MAX}.")
        confirmed = request.get("confirmedCount")
        if not isinstance(confirmed, int) or isinstance(confirmed, bool) or confirmed < 0:
            raise RequestError("badRequest", "confirmedCount is required: the number of items the user confirmed, 0 or more.")
        ids = set(str(i) for i in (request.pop("ids", None) or []))
        hints = request.get("hints") or {}
        run = _DeleteRun(self, request_id, timer)
        missing = 0
        stopped = message = None
        try:
            targets = self._delete_targets(self._album(spec["album"]), mode, ids, hints, run)
            if not run.should_stop():
                if len(targets) > confirmed:
                    # The album changed since the user confirmed: change nothing, not even the confirmed part.
                    stopped, message = "changed", spec["changed"]
                else:
                    run.targets([target.id for target in targets])
                    missing = len(ids) - len(targets) if mode == "only" else 0
                    run.deleting(targets, batch_size, spec["isDeleted"])
        except DeleteStopped as stop:
            stopped, message = stop.kind, stop.message
        except DownloadStopped as error:
            stopped, message = "throttled", str(error)
        except Exception as error:  # noqa: BLE001
            if not is_run_ending(error):
                self.channel.forget(request_id)
                raise
            stopped, message = "throttled", str(error)
        run.finish(missing=missing, stopped=stopped, message=message)

    def _delete_targets(self, album: Any, mode: str, ids: set, hints: Dict[str, Any], run: "_DeleteRun") -> List["_DeleteTarget"]:
        targets: List[_DeleteTarget] = []
        if mode == "allExcept":
            total = len(album)
            run.progress("finding", 0, total)
            for _, asset in walk(album):
                if run.should_stop():
                    break
                if asset.id not in ids:
                    targets.append(_DeleteTarget.of(asset))
                run.tick("finding", len(targets), total)
            return targets
        remaining = set(ids)
        run.progress("finding", 0, len(ids))
        for _, asset in self._hinted(album, remaining, hints, run):
            remaining.discard(asset.id)
            targets.append(_DeleteTarget.of(asset))
            run.progress("finding", len(targets), len(ids))
        if remaining and not run.should_stop():
            for _, asset in walk(album):
                if run.should_stop():
                    break
                if asset.id in remaining:
                    remaining.discard(asset.id)
                    targets.append(_DeleteTarget.of(asset))
                    run.progress("finding", len(targets), len(ids))
                    if not remaining:
                        break
                else:
                    run.tick("finding", len(targets), len(ids))
        return targets

    def _modify_batch(self, batch: List["_DeleteTarget"], is_deleted: int) -> tuple:
        """One CloudKit modify request setting isDeleted. Returns (changed IDs, [(id, reason)] for the items that failed)."""
        library = self.library
        url = f"{library.service_endpoint}/records/modify?{urllib.parse.urlencode(library.params)}"
        body = {
            "atomic": False,
            "desiredKeys": ["isDeleted"],
            "operations": [
                {
                    "operationType": "update",
                    "record": {
                        "fields": {"isDeleted": {"value": is_deleted}},
                        "recordChangeTag": target.change_tag,
                        "recordName": target.record_name,
                        "recordType": "CPLAsset",
                    },
                }
                for target in batch
            ],
            "zoneID": library.zone_id,
        }
        response = library.session.post(url, data=json.dumps(body), headers={"Content-type": "application/json"})
        status = getattr(response, "status_code", 200)
        if status == 429 or 500 <= status < 600:
            raise DeleteStopped("throttled", f"iCloud answered with HTTP {status}.")
        if not response.ok:
            reason = f"iCloud answered with HTTP {response.status_code}."
            return [], [(target.id, reason) for target in batch]
        try:
            records = response.json().get("records")
        except (ValueError, AttributeError):
            records = None
        answers: Dict[str, Any] = {}
        for record in records if isinstance(records, list) else []:
            if isinstance(record, dict) and "recordName" in record:
                answers[record["recordName"]] = record
        deleted: List[str] = []
        failures: List[tuple] = []
        for target in batch:
            answer = answers.get(target.record_name)
            if answer is None:
                failures.append((target.id, "No response from iCloud."))
            elif "serverErrorCode" in answer:
                failures.append((target.id, str(answer.get("reason") or answer["serverErrorCode"])))
            else:
                deleted.append(target.id)
        return deleted, failures


class _RequestRun:
    """What a long request (a download or a delete) needs from the request loop: pings, pause and cancel."""

    def __init__(self, bridge: Bridge, request_id: Any, timer: Optional[RequestTimer] = None):
        self.bridge = bridge
        self.channel = bridge.channel
        self.request_id = request_id
        self.timer = timer

    def should_stop(self) -> bool:
        """Checked before each item: answers pings, holds while paused, then says whether to stop."""
        self.channel.answer_pings()
        self.hold()
        return self.channel.is_cancelled(self.request_id)

    def hold(self) -> bool:
        """Waits while the request is paused, answering browsing requests. False once cancelled."""
        while self.channel.is_paused(self.request_id) and not self.channel.is_cancelled(self.request_id):
            self.bridge.serve_waiting()
            self.channel.wait_for_input(0.05)
        return not self.channel.is_cancelled(self.request_id)

    def _timing(self, items: int) -> Dict[str, Any]:
        """The `timing` key for this request's final event (nothing when it isn't timed)."""
        return timing_field(self.timer, items)


class _DeleteTarget:
    """What a delete batch needs of an item: its IDs, not the whole asset object."""

    __slots__ = ("id", "record_name", "change_tag")

    def __init__(self, asset_id: str, record_name: str, change_tag: str):
        self.id = asset_id
        self.record_name = record_name
        self.change_tag = change_tag

    @classmethod
    def of(cls, asset: Any) -> "_DeleteTarget":
        record = asset._asset_record
        return cls(asset.id, record["recordName"], record["recordChangeTag"])


class _DeleteRun(_RequestRun):
    """Reports a delete's progress and runs its batches; see Bridge.delete."""

    def __init__(self, bridge: Bridge, request_id: Any, timer: Optional[RequestTimer] = None):
        super().__init__(bridge, request_id, timer)
        self._announced: Optional[tuple] = None
        self._ticks = 0
        self.counts = {"deleted": 0, "failed": 0}

    def progress(self, phase: str, done: int, total: int) -> None:
        state = (phase, done, total)
        if state != self._announced:
            self._announced = state
            self.channel.send({
                "id": self.request_id, "event": "deleteProgress", "phase": phase, "done": done, "total": total,
            })

    def tick(self, phase: str, done: int, total: int) -> None:
        """Called per item while resolving targets: reports progress and answers browsing once per page."""
        self._ticks += 1
        if self._ticks % PAGE_CHUNK == 0:
            self.progress(phase, done, total)
            self.bridge.serve_waiting()

    def targets(self, ids: List[str]) -> None:
        self.channel.send({"id": self.request_id, "event": "deleteTargets", "ids": ids})

    def deleting(self, targets: List["_DeleteTarget"], batch_size: int, is_deleted: int) -> None:
        total = len(targets)
        self.progress("deleting", 0, total)
        streak = 0
        for start in range(0, total, batch_size):
            if start:
                self.pace(DELETE_PACE)
            if self.should_stop():
                break
            batch = targets[start:start + batch_size]
            try:
                deleted, failures = self.bridge._modify_batch(batch, is_deleted)
            except DeleteStopped:
                raise
            except Exception as error:  # noqa: BLE001
                if is_run_ending(error) or is_throttle_error(error):
                    # Not this batch's fault: the items it didn't reach stay as they are, for a retry.
                    raise DeleteStopped("throttled", str(error))
                deleted, failures = [], [(target.id, f"{type(error).__name__}: {error}") for target in batch]
            if deleted:
                self.counts["deleted"] += len(deleted)
                self.channel.send({"id": self.request_id, "event": "deleted", "ids": deleted})
            if failures:
                self.counts["failed"] += len(failures)
                self.channel.send({
                    "id": self.request_id, "event": "deleteFailed",
                    "failures": [{"id": asset_id, "reason": reason} for asset_id, reason in failures],
                })
            self.progress("deleting", start + len(batch), total)
            if not deleted and len(failures) == len(batch):
                streak += 1
                if streak >= DELETE_FAILURE_STREAK:
                    raise DeleteStopped("error", failures[-1][1])
            else:
                streak = 0

    def pace(self, seconds: float) -> None:
        """Waits between batches, answering browsing and pings, and ends early on cancel."""
        deadline = time.monotonic() + seconds
        while not self.channel.is_cancelled(self.request_id) and time.monotonic() < deadline:
            self.bridge.serve_waiting()
            self.channel.wait_for_input(min(0.05, max(0.0, deadline - time.monotonic())))

    def finish(self, missing: int, stopped: Optional[str], message: Optional[str]) -> None:
        cancelled = self.channel.is_cancelled(self.request_id)
        self.channel.forget(self.request_id)
        self.channel.send({
            "id": self.request_id, "event": "deleteDone", "deleted": self.counts["deleted"],
            "failed": self.counts["failed"], "missing": missing, "cancelled": cancelled,
            "stopped": stopped, "message": message,
            **self._timing(self.counts["deleted"] + self.counts["failed"]),
        })


class _DownloadRun(_RequestRun):
    def __init__(self, bridge: Bridge, request_id: Any, plan: DownloadPlan, timer: Optional[RequestTimer] = None):
        super().__init__(bridge, request_id, timer)
        self.plan = plan
        self.total = 0
        self.done = 0
        self.counts = {"downloaded": 0, "skipped": 0, "failed": 0}
        self._announced: Optional[tuple] = None
        self._since_poll = 0
        self._served_at = float("-inf")
        self._idle_streak = 0

    def between_chunks(self) -> Optional[str]:
        """Checked after each chunk of a file: "cancel", "pause" or None."""
        self.channel.answer_pings()
        self._serve_browsing_if_due()
        if self.channel.is_cancelled(self.request_id):
            return "cancel"
        if self.channel.is_paused(self.request_id):
            return "pause"
        return None

    def _serve_browsing_if_due(self) -> None:
        """Answers the browsing requests that arrived during the download, at most every SERVE_INTERVAL seconds.
        Without this a large file would hold up the library grid until it finished."""
        now = CLOCK()
        if now - self._served_at < SERVE_INTERVAL:
            return
        self._served_at = now
        # At most two requests, and about a second: the rest wait for the next interval, so a slow page can't stall the file.
        self.bridge.serve_waiting(limit=BROWSE_REQUESTS_PER_CHUNK, seconds=BROWSE_SECONDS_PER_CHUNK)

    def set_total(self, total: int) -> None:
        self.total = max(0, total)
        self._progress()

    def _progress(self) -> None:
        state = (self.done, self.total)
        if state != self._announced:
            self._announced = state
            self.channel.send({"id": self.request_id, "event": "progress", "done": self.done, "total": self.total})

    def idle(self, rank: Optional[int] = None) -> None:
        """Called for items passed over, so browsing stays answered during long scans. With a rank, the walk's
        position is reported every PAGE_CHUNK items too."""
        self._since_poll += 1
        self._idle_streak += 1
        if self._since_poll >= PAGE_CHUNK:
            self._since_poll = 0
            if rank is not None:
                self.channel.send({"id": self.request_id, "event": "walked", "rank": rank})
            self.bridge.serve_waiting()

    def mostly_idle(self) -> bool:
        """Whether the walk has passed over most of the last page (a long run of known items, not downloads)."""
        return self._idle_streak >= PAGE_CHUNK // 2

    def process(self, asset: Any, rank: Optional[int] = None) -> None:
        global _ACTIVE_RUN
        self._idle_streak = 0
        capture = self.bridge.capture
        capture.reset()
        filename = asset.id
        _ACTIVE_RUN = self
        try:
            filename = self.plan.filename_builder(asset)
            if self.plan.passer(asset):
                self.plan.downloader(self.bridge.icloud, _counter(), asset)
        except DownloadCancelled:
            # Stopped mid-file: the item isn't done, and its partial file is gone.
            capture.reset()
            return
        except Exception as error:  # noqa: BLE001
            if is_run_ending(error):
                # Not this item's fault: every item after it would fail the same way.
                capture.reset()
                raise DownloadStopped(error, asset.id, rank)
            capture.errors.append(f"{type(error).__name__}: {error}")
        finally:
            _ACTIVE_RUN = None
        downloaded, existing, errors = list(capture.downloaded), list(capture.existing), list(capture.errors)
        files = list(capture.files)
        capture.reset()
        if files and getattr(getattr(self.plan, "user_config", None), "xmp_sidecar", False):
            sidecar = files[0] + ".xmp"
            if os.path.isfile(sidecar):
                files.append(sidecar)

        base = {"id": self.request_id, "asset": asset.id, "filename": filename}
        if rank is not None:
            base["rank"] = rank
        if errors:
            self.counts["failed"] += 1
            self.channel.send({**base, "event": "failed", "reason": errors[0], "paths": downloaded})
        elif downloaded:
            self.counts["downloaded"] += 1
            self.channel.send({
                **base, "event": "downloaded", "path": downloaded[0], "paths": downloaded, "files": files,
            })
        elif existing:
            self.counts["skipped"] += 1
            self.channel.send({**base, "event": "skipped", "path": existing[0], "paths": existing, "files": files})
        else:
            self.counts["failed"] += 1
            self.channel.send({**base, "event": "failed", "reason": "iCloud didn't offer a file for this item."})
        self.done += 1
        self._progress()
        self._since_poll = 0
        self.bridge.serve_waiting()

    def finish(self) -> None:
        self._progress()
        cancelled = self.channel.is_cancelled(self.request_id)
        self.channel.forget(self.request_id)
        self.channel.send({
            "id": self.request_id, "event": "done", "cancelled": cancelled, **self.counts,
            **self._timing(self.done),
        })

    def stop(self, stopped: DownloadStopped) -> None:
        """Ends the download with a run-ending error instead of `done`; the app treats it as the run's
        failure (Apple's throttle maps to serviceUnavailable, which resumes automatically)."""
        self._progress()
        self.channel.forget(self.request_id)
        reply: Dict[str, Any] = {
            "id": self.request_id, "event": "error", "kind": stopped.kind, "message": str(stopped), **self.counts,
        }
        if stopped.asset_id is not None:
            reply["asset"] = stopped.asset_id
        if stopped.rank is not None:
            reply["rank"] = stopped.rank
        reply.update(self._timing(self.done))
        self.channel.send(reply)


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

    patch_icloudpd_for_bridge(lambda message: channel.send({"event": "note", "message": message}))
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
