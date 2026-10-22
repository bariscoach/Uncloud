"""A stand-in for photo_bridge.py, for tests of the app's process handling. No network, no account.

Usage: python3 fake_bridge.py [fake options] -- -u APPLE_ID --cookie-directory DIR

Fake options:
  --total N           items in the library (default 1000), IDs "asset-0" ... "asset-(N-1)"; asset-i is the
                      item at rank i. Used only when there is no --state file yet.
  --rate R            downloads per second; 0 means as fast as possible (default 50)
  --auth-delay S      seconds before "ready" (default 0)
  --launch-log PATH   append "<pid> bridge" to PATH at start, then "<pid> page offset=N" for each page request,
                      "<pid> download-start <id> startRank=R mode=M layout=L [stopAt=ID] ids=N" for each
                      download (N: how many IDs the request carried), and
                      "<pid> download-ended <id>" when a download ends in the bridge
  --stats-delay S     seconds per stats page of 100 items (default 0)
  --chunks N          chunks per downloaded file (default 1)
  --chunk-delay S     seconds per chunk (default 0), for slow downloads of large files
  --stuck             a download never checks for cancel or pings: the bridge looks hung
  --remove-dest-at N  in a download, the Nth item (counted from 0) finds the destination gone: the fake
                      deletes the destination folder and reports that item failed, as a vanished drive would;
                      then it waits for the cancel the app sends and finishes the chunk in progress
  --state PATH        the library's order, kept in this JSON file across launches. Created on first use from
                      --total. The --insert-at and --delete-at changes below are written back to it, so the
                      next launch sees them. Without --state, changes last for this launch only.
  --insert-at N       before serving, insert --insert-count new items at rank N (0 prepends, len appends).
                      New items get new IDs and file names that are never reused, even after a delete.
  --insert-count K    how many items --insert-at adds (default 1)
  --delete-at N       before serving, remove the item at rank N. Its file, if already downloaded, stays on disk.
                      Changes apply in the order: delete, then insert. Ranks refer to the list as it stands
                      at that step, and an out-of-range rank is a usage error (exit status 2).
  --throttle-after N  a download ends with a service-unavailable error (the bridge's reply for Apple's 503)
                      when it reaches item N+1 that needs downloading. The N new items before it are
                      downloaded. Counted across all downloads in this launch; skipped items don't count.
  --live-every K      item numbers divisible by K (K > 0) are Live Photos: IMG_NNNNNN.JPG plus IMG_NNNNNN.MOV
  --movie-fails-at N  item number N's Live Photo movie fails to download: its photo is written, and the item is
                      reported "failed" with "paths" listing the photo, as the bridge reports a half-done item
  --same-name-every K item numbers with N % K == 1 (K > 1) get item N-1's file name. Every photo is then exactly
                      fake_bytes(N) bytes, and a name taken by a file of another size gets the size added, as
                      icloudpd's name-size-dedup-with-suffix does: IMG_000000-1001.JPG (fake_icloudpd agrees)
  --delete-batch-delay S  seconds each delete batch takes (default 0), for cancel and pause tests
  --delete-throttle-after N  the Nth delete batch of this launch (counting from 0, throttled ones included) is
                      throttled: the run ends with "stopped":"throttled", as Apple's 503 ends it. Later requests go through.
  --delete-fail-every K  items whose number is divisible by K (K > 0) fail to delete with a server error
  --trash-first N     without a --state file, the first N items start in Recently Deleted instead of the library
  --hidden N          the library's count is N larger than the items it lists: iCloud counts N items that no
                      listing or walk reaches, so they can never be downloaded

Speaks the bridge's JSON-lines protocol (page, count, albums, download, stats, cancel, pause, resume,
ping) closely enough for the app: "ready" after signing in, downloads write DEST/YYYY/MM files through
a ".part" file and report progress/downloaded/skipped/failed with the item's "rank", and a final done with
"cancelled". Like the real bridge, a download checks for cancel, pause and pings after every chunk (a cancel
removes the partial file) and answers page, count, albums and ping requests between chunks and items and while
paused.

Downloaded and skipped events carry "paths" (the files written, or found) and "files" (every file the item has
on disk now, plus its XMP sidecar when the request asks for sidecars, written as NAME.xmp next to the photo).

Ranks: rank 0 is the newest item, as in icloudpd's walk, so an item added since the last walk is inserted at
rank 0 and shifts every older item's rank by one. A page reply lists items from the "offset" rank on, with
"rank" set on each. A download request walks ranks from "startRank" (default 0) to the end (or, with "stopAt", to just
before that asset), and
"layout": "none" puts files directly in DEST instead of DEST/YYYY/MM. Item i (by ID number) is
fake_bytes(i) bytes in page and stats replies, and its file is IMG_NNNNNN.JPG.

Delete requests ("delete", with "mode", "ids", "hints" and "batchSize") move items from the library to Recently
Deleted, so the next count and page reflect them. Restore requests ("restore", the same fields) move items from
Recently Deleted back into the library, at the top of its order (the fake doesn't keep their old places). Page and
count take "album": "recentlyDeleted" to read Recently Deleted; any other album other than "library" is a badRequest.
Both reply with the deleteProgress, deleteTargets, deleted, deleteFailed and deleteDone events of the real bridge;
--state, if given, is rewritten with the library order and Recently Deleted.

Closing stdin ends it; SIGTERM, SIGSTOP and SIGCONT keep their default meaning.
"""

import datetime
import json
import os
import queue
import shutil
import signal
import sys
import threading
import time

THROTTLE_KIND = "PyiCloudServiceUnavailableException"
THROTTLE_MESSAGE = "Apple iCloud is temporary refusing to serve icloudpd"


def parse(argv):
    fake = {"total": 1000, "rate": 50.0, "auth_delay": 0.0, "launch_log": None, "stats_delay": 0.0,
            "chunks": 1, "chunk_delay": 0.0, "stuck": False, "remove_dest_at": None,
            "state": None, "insert_at": None, "insert_count": 1, "delete_at": None, "throttle_after": None,
            "live_every": 0, "movie_fails_at": None, "same_name_every": 0,
            "delete_batch_delay": 0.0, "delete_throttle_after": None, "delete_fail_every": 0, "trash_first": 0,
            "hidden": 0}
    own = argv[:argv.index("--")] if "--" in argv else []
    index = 0
    while index < len(own):
        flag = own[index]
        if flag == "--total":
            fake["total"] = int(own[index + 1]); index += 2
        elif flag == "--rate":
            fake["rate"] = float(own[index + 1]); index += 2
        elif flag == "--auth-delay":
            fake["auth_delay"] = float(own[index + 1]); index += 2
        elif flag == "--stats-delay":
            fake["stats_delay"] = float(own[index + 1]); index += 2
        elif flag == "--chunks":
            fake["chunks"] = max(1, int(own[index + 1])); index += 2
        elif flag == "--chunk-delay":
            fake["chunk_delay"] = float(own[index + 1]); index += 2
        elif flag == "--launch-log":
            fake["launch_log"] = own[index + 1]; index += 2
        elif flag == "--stuck":
            fake["stuck"] = True; index += 1
        elif flag == "--remove-dest-at":
            fake["remove_dest_at"] = int(own[index + 1]); index += 2
        elif flag == "--state":
            fake["state"] = own[index + 1]; index += 2
        elif flag == "--insert-at":
            fake["insert_at"] = int(own[index + 1]); index += 2
        elif flag == "--insert-count":
            fake["insert_count"] = int(own[index + 1]); index += 2
        elif flag == "--delete-at":
            fake["delete_at"] = int(own[index + 1]); index += 2
        elif flag == "--throttle-after":
            fake["throttle_after"] = int(own[index + 1]); index += 2
        elif flag == "--live-every":
            fake["live_every"] = int(own[index + 1]); index += 2
        elif flag == "--movie-fails-at":
            fake["movie_fails_at"] = int(own[index + 1]); index += 2
        elif flag == "--same-name-every":
            fake["same_name_every"] = int(own[index + 1]); index += 2
        elif flag == "--delete-batch-delay":
            fake["delete_batch_delay"] = float(own[index + 1]); index += 2
        elif flag == "--delete-throttle-after":
            fake["delete_throttle_after"] = int(own[index + 1]); index += 2
        elif flag == "--trash-first":
            fake["trash_first"] = int(own[index + 1]); index += 2
        elif flag == "--delete-fail-every":
            fake["delete_fail_every"] = int(own[index + 1]); index += 2
        elif flag == "--hidden":
            fake["hidden"] = int(own[index + 1]); index += 2
        else:
            index += 1
    return fake


def load_library(fake):
    """The library's order and Recently Deleted, as lists of (asset ID, item number), rank 0 first, after the
    --state changes. Returns (order, trash)."""
    state = fake["state"]
    if state and os.path.exists(state):
        with open(state, encoding="utf-8") as handle:
            data = json.load(handle)
        order = [(asset_id, number) for asset_id, number in data["order"]]
        trash = [(asset_id, number) for asset_id, number in data.get("trash", [])]
        next_number = int(data["next"])
    else:
        order = [(f"asset-{i}", i) for i in range(fake["total"])]
        trash = order[:fake["trash_first"]]
        order = order[fake["trash_first"]:]
        next_number = fake["total"]
    if fake["delete_at"] is not None:
        if not 0 <= fake["delete_at"] < len(order):
            sys.stderr.write(f"fake bridge: --delete-at {fake['delete_at']} is outside 0..{len(order) - 1}\n")
            sys.exit(2)
        del order[fake["delete_at"]]
    if fake["insert_at"] is not None:
        if not 0 <= fake["insert_at"] <= len(order):
            sys.stderr.write(f"fake bridge: --insert-at {fake['insert_at']} is outside 0..{len(order)}\n")
            sys.exit(2)
        added = [(f"asset-{next_number + k}", next_number + k) for k in range(fake["insert_count"])]
        order[fake["insert_at"]:fake["insert_at"]] = added
        next_number += len(added)
    if state and (fake["insert_at"] is not None or fake["delete_at"] is not None or not os.path.exists(state)):
        with open(state, "w", encoding="utf-8") as handle:
            json.dump({"order": [list(item) for item in order], "trash": [list(item) for item in trash],
                       "next": next_number}, handle)
    return order, trash


class Channel:
    def __init__(self, out):
        self.out = out
        self.lock = threading.Lock()
        self.requests = queue.Queue()
        self.cancelled = set()
        self.paused = set()
        self.pings = []
        self.closed = threading.Event()

    def send(self, message):
        with self.lock:
            try:
                self.out.write(json.dumps(message) + "\n")
                self.out.flush()
            except (BrokenPipeError, OSError, ValueError):
                self.closed.set()

    def read(self, stream):
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            command = message.get("cmd")
            with self.lock:
                if command == "cancel":
                    self.cancelled.add(message.get("target"))
                    continue
                if command == "pause":
                    self.paused.add(message.get("target"))
                    continue
                if command == "resume":
                    self.paused.discard(message.get("target"))
                    continue
                if command == "ping":
                    self.pings.append(message.get("id"))
            self.requests.put(message)
        self.closed.set()
        self.requests.put(None)

    def answer_pings(self):
        with self.lock:
            pings, self.pings = self.pings, []
        for ping_id in pings:
            self.send({"id": ping_id, "event": "pong"})

    def is_cancelled(self, request_id):
        with self.lock:
            return self.closed.is_set() or request_id in self.cancelled

    def is_paused(self, request_id):
        with self.lock:
            return request_id in self.paused


def filename(index):
    return f"IMG_{index:06d}.JPG"


def display_name(fake, index):
    """The item's file name in iCloud: with --same-name-every K, items N % K == 1 share item N-1's name."""
    every = fake.get("same_name_every") or 0
    if every > 1 and index % every == 1:
        return filename(index - 1)
    return filename(index)


def item_path(dest, index, flat=False, fake=None):
    name = display_name(fake, index) if fake else filename(index)
    if flat:
        path = os.path.join(dest, name)
    else:
        year = 2001 + index // 1200
        month = 1 + (index // 100) % 12
        path = os.path.join(dest, f"{year:04d}", f"{month:02d}", name)
    if fake and (fake.get("same_name_every") or 0) > 1:
        # icloudpd's name-size-dedup-with-suffix: a name taken by a file of another size gets the size added.
        size = fake_bytes(index)
        if os.path.exists(path) and os.path.getsize(path) != size:
            stem, ext = os.path.splitext(path)
            path = f"{stem}-{size}{ext}"
    return path


def fake_added(index):
    """The fake's added date, an ISO 8601 UTC string: a later item number was added later, one minute apart."""
    moment = datetime.datetime(2024, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(minutes=index)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def fake_bytes(index):
    return 1000 + index


class Bridge:
    def __init__(self, channel, fake, order, trash):
        self.channel = channel
        self.fake = fake
        self.order = order
        self.trash = trash
        self.total = len(order)
        self.deferred = []
        self.downloaded = 0
        self.delete_batches = 0
        self.delete_attempts = 0

    def log(self, text):
        if self.fake["launch_log"]:
            with open(self.fake["launch_log"], "a") as handle:
                handle.write(f"{os.getpid()} {text}\n")

    def serve(self):
        while True:
            request = self.deferred.pop(0) if self.deferred else self.channel.requests.get()
            if request is None:
                return 0
            self.handle(request, busy=False)

    def serve_waiting(self):
        """Browsing requests that arrived during a download or a stats walk; long ones wait."""
        self.channel.answer_pings()
        while True:
            try:
                request = self.channel.requests.get_nowait()
            except queue.Empty:
                return
            if request is None:
                self.channel.requests.put(None)
                return
            self.handle(request, busy=True)

    def handle(self, request, busy):
        command = request.get("cmd")
        request_id = request.get("id")
        total = self.total
        if command == "ping":
            self.channel.answer_pings()
        elif command == "count":
            rows = self.album_rows(request.get("album"))
            if rows is None:
                self.channel.send({"id": request_id, "event": "error", "kind": "badRequest",
                                   "message": "album must be library or recentlyDeleted."})
                return
            hidden = self.fake["hidden"] if request.get("album") in (None, "library") else 0
            self.channel.send({"id": request_id, "event": "count", "count": len(rows) + hidden})
        elif command == "albums":
            self.channel.send({"id": request_id, "event": "albums", "albums": ["Trip"]})
        elif command == "page":
            offset = max(0, int(request.get("offset", 0)))
            limit = int(request.get("limit", 200))
            rows = self.album_rows(request.get("album"))
            if rows is None:
                self.channel.send({"id": request_id, "event": "error", "kind": "badRequest",
                                   "message": "album must be library or recentlyDeleted."})
                return
            self.log(f"page offset={offset}")
            items = []
            for rank in range(offset, min(len(rows), offset + limit)):
                asset_id, number = rows[rank]
                items.append({"id": asset_id, "rank": rank, "filename": display_name(self.fake, number), "created": None,
                              "added": fake_added(number),
                              "type": "image", "size": fake_bytes(number), "bytes": fake_bytes(number),
                              "thumbURL": None})
            self.channel.send({"id": request_id, "event": "page", "offset": offset, "items": items})
        elif command in ("download", "stats", "delete", "restore") and busy:
            self.deferred.append(request)
        elif command == "download":
            self.download(request)
        elif command == "stats":
            self.stats(request)
        elif command in ("delete", "restore"):
            self.delete(request, command)
        else:
            self.channel.send({"id": request_id, "event": "error", "kind": "badRequest", "message": "unknown"})

    def album_rows(self, name):
        """The rows of the album a request names, or None for a name the fake doesn't have."""
        if name in (None, "library"):
            return self.order
        if name == "recentlyDeleted":
            return self.trash
        return None

    def delete(self, request, action="delete"):
        """Resolves the targets from the album (rank by rank), then moves them in batches, as the real bridge does:
        a delete moves them from the library to Recently Deleted, a restore back to the top of the library."""
        channel = self.channel
        request_id = request.get("id")
        only = request.get("mode") == "only"
        ids = set(request.get("ids") or [])
        size = int(request.get("batchSize") or 100)
        confirmed = request.get("confirmedCount")
        if not isinstance(confirmed, int) or isinstance(confirmed, bool) or confirmed < 0:
            channel.send({"id": request_id, "event": "error", "kind": "badRequest", "message": "confirmedCount"})
            return
        self.log(f"delete-start {request_id} action={action} mode={'only' if only else 'allExcept'} ids={len(ids)} confirmed={confirmed}")
        source = self.order if action == "delete" else self.trash
        channel.send({"id": request_id, "event": "deleteProgress", "phase": "finding", "done": 0, "total": len(source)})
        chosen = [asset_id for asset_id, _ in source if (asset_id in ids) == only]
        if len(chosen) > confirmed:
            with channel.lock:
                channel.cancelled.discard(request_id)
                channel.paused.discard(request_id)
            message = ("Your iCloud library changed since you confirmed, so nothing was deleted. Review your selection and try again."
                       if action == "delete" else
                       "Your iCloud library changed since you confirmed, so nothing was recovered. Review your selection and try again.")
            channel.send({"id": request_id, "event": "deleteDone", "deleted": 0, "failed": 0, "missing": 0,
                          "cancelled": False, "stopped": "changed", "message": message})
            return
        channel.send({"id": request_id, "event": "deleteTargets", "ids": chosen})
        missing = len(ids) - len(chosen) if only else 0
        numbers = {asset_id: number for asset_id, number in self.order + self.trash}
        deleted = failed = 0
        stopped = message = None
        done = 0
        streak = 0
        for start in range(0, len(chosen), size):
            if start:
                time.sleep(self.fake["delete_batch_delay"])
            self.channel.answer_pings()
            if not self.hold(request_id) or channel.is_cancelled(request_id):
                break
            batch = chosen[start:start + size]
            attempt = self.delete_attempts
            self.delete_attempts += 1
            if attempt == self.fake["delete_throttle_after"]:
                stopped, message = "throttled", THROTTLE_MESSAGE
                break
            self.delete_batches += 1
            ok, bad = [], []
            for asset_id in batch:
                number = numbers[asset_id]
                if self.fake["delete_fail_every"] and number % self.fake["delete_fail_every"] == 0:
                    bad.append({"id": asset_id, "reason": "The item couldn't be deleted."})
                else:
                    ok.append(asset_id)
            gone = set(ok)
            if action == "delete":
                moved = [(asset_id, number) for asset_id, number in self.order if asset_id in gone]
                self.order = [(asset_id, number) for asset_id, number in self.order if asset_id not in gone]
                self.trash = self.trash + moved
            else:
                moved = [(asset_id, number) for asset_id, number in self.trash if asset_id in gone]
                self.trash = [(asset_id, number) for asset_id, number in self.trash if asset_id not in gone]
                self.order = moved + self.order
            if self.fake["state"]:
                with open(self.fake["state"], "w", encoding="utf-8") as handle:
                    next_number = max([number for _, number in self.order + self.trash] + [self.total]) + 1
                    json.dump({"order": [list(item) for item in self.order], "trash": [list(item) for item in self.trash],
                               "next": next_number}, handle)
            self.total = len(self.order)
            deleted += len(ok)
            failed += len(bad)
            if ok:
                channel.send({"id": request_id, "event": "deleted", "ids": ok})
            if bad:
                channel.send({"id": request_id, "event": "deleteFailed", "failures": bad})
            done += len(batch)
            channel.send({"id": request_id, "event": "deleteProgress", "phase": "deleting", "done": done, "total": len(chosen)})
            if bad and not ok:
                streak += 1
                if streak >= 3:
                    stopped, message = "error", bad[-1]["reason"]
                    break
            else:
                streak = 0
            self.serve_waiting()
        cancelled = channel.is_cancelled(request_id)
        with channel.lock:
            channel.cancelled.discard(request_id)
            channel.paused.discard(request_id)
        channel.send({"id": request_id, "event": "deleteDone", "deleted": deleted, "failed": failed,
                      "missing": missing, "cancelled": cancelled, "stopped": stopped, "message": message})

    def stats(self, request):
        channel = self.channel
        request_id = request.get("id")
        offset = max(0, int(request.get("offset") or 0))
        self.log(f"stats offset={offset}")
        total = self.total
        done = 0
        total_bytes = 0
        complete = True
        for start in range(offset, total, 100):
            sizes = {self.order[i][0]: fake_bytes(self.order[i][1])
                     for i in range(start, min(total, start + 100))}
            if self.fake["stats_delay"] > 0:
                time.sleep(self.fake["stats_delay"])
            done += len(sizes)
            total_bytes += sum(sizes.values())
            page_items = []
            for rank in range(start, min(total, start + 100)):
                asset_id, number = self.order[rank]
                page_items.append({"id": asset_id, "rank": rank, "filename": display_name(self.fake, number),
                                   "created": None, "added": fake_added(number), "type": "image",
                                   "size": fake_bytes(number), "bytes": fake_bytes(number),
                                   "master": asset_id, "lat": None, "lon": None, "tz": None})
            channel.send({"id": request_id, "event": "statsProgress", "done": done, "total": total,
                          "bytes": total_bytes, "sizes": sizes, "unsized": [], "items": page_items})
            if channel.is_cancelled(request_id):
                complete = False
                break
            self.serve_waiting()
            if self.deferred:
                complete = start + 100 >= total
                break
        cancelled = channel.is_cancelled(request_id)
        channel.send({"id": request_id, "event": "stats", "done": done, "total": total, "bytes": total_bytes,
                      "complete": complete, "cancelled": cancelled})

    def hold(self, request_id):
        """Waits while the download is paused, answering browsing. False once cancelled."""
        while self.channel.is_paused(request_id) and not self.channel.is_cancelled(request_id):
            self.serve_waiting()
            time.sleep(0.01)
        return not self.channel.is_cancelled(request_id)

    def write_item(self, request_id, path, index):
        """Writes one file in chunks; False (and no partial file) when cancelled midway."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        part = path + ".part"
        with open(part, "wb") as handle:
            for chunk in range(self.fake["chunks"]):
                handle.write(f"photo {index} chunk {chunk}\n".encode())
                handle.flush()
                if self.fake["chunk_delay"] > 0:
                    time.sleep(self.fake["chunk_delay"])
                if self.fake["stuck"]:
                    continue
                self.channel.answer_pings()
                if self.channel.is_cancelled(request_id) or not self.hold(request_id):
                    handle.close()
                    os.remove(part)
                    return False
                self.serve_waiting()
            if (self.fake["same_name_every"] or 0) > 1 and not path.endswith(".MOV"):
                padding = fake_bytes(index) - handle.tell()
                if padding > 0:
                    handle.write(b"\0" * padding)
                else:
                    handle.truncate(fake_bytes(index))
        os.replace(part, path)
        return True

    def end(self, request_id, reply):
        """Clears the download's cancel and pause marks, logs its end, and sends its final reply."""
        with self.channel.lock:
            self.channel.cancelled.discard(request_id)
            self.channel.paused.discard(request_id)
        # Logged when the download has really ended in the bridge, before its final reply.
        self.log(f"download-ended {request_id}")
        self.channel.send(reply)

    def download(self, request):
        channel = self.channel
        request_id = request.get("id")
        ids = set(request.get("ids") or [])
        only = request.get("mode") == "only"
        start_rank = max(0, int(request.get("startRank") or 0))
        layout = request.get("layout") or "month"
        flat = layout == "none"
        stop_at = request.get("stopAt")
        self.log(f"download-start {request_id} startRank={start_rank} "
                 f"mode={'only' if only else 'allExcept'} layout={layout}"
                 + (f" stopAt={stop_at}" if stop_at else "") + f" ids={len(ids)}")
        walked = self.order
        if stop_at is not None:
            ranks = [rank for rank, (asset_id, _) in enumerate(self.order) if asset_id == stop_at and rank >= start_rank]
            if ranks:
                walked = self.order[:ranks[0]]
        chosen = [(rank, asset_id, number)
                  for rank, (asset_id, number) in enumerate(walked)
                  if rank >= start_rank and ((asset_id in ids) == only)]
        counts = {"downloaded": 0, "skipped": 0, "failed": 0}
        channel.send({"id": request_id, "event": "progress", "done": 0, "total": len(chosen)})
        if not only:
            # A walk reports each page it accepts, as the bridge does (R12g); counts don't change.
            for low in range(start_rank, len(walked), 100):
                listed = []
                for rank in range(low, min(len(walked), low + 100)):
                    asset_id, number = walked[rank]
                    listed.append({"id": asset_id, "rank": rank, "filename": display_name(self.fake, number),
                                   "created": None, "added": fake_added(number), "type": "image",
                                   "size": fake_bytes(number), "bytes": fake_bytes(number),
                                   "master": asset_id, "lat": None, "lon": None, "tz": None})
                channel.send({"id": request_id, "event": "listed", "offset": low, "items": listed})
        rate = self.fake["rate"]
        started = time.monotonic()
        done = 0
        for position, (rank, asset, number) in enumerate(chosen):
            if not self.fake["stuck"]:
                self.channel.answer_pings()
                if not self.hold(request_id):
                    break
            if channel.is_cancelled(request_id):
                break
            path = item_path(request["dest"], number, flat, self.fake)
            base = {"id": request_id, "asset": asset, "rank": rank, "filename": display_name(self.fake, number)}
            if position == self.fake["remove_dest_at"]:
                shutil.rmtree(request["dest"], ignore_errors=True)
                counts["failed"] += 1
                channel.send({**base, "event": "failed", "reason": "[Errno 2] No such file or directory"})
                done += 1
                channel.send({"id": request_id, "event": "progress", "done": done, "total": len(chosen)})
                # The app stops a failed download by cancelling it. Like a bridge, this one finishes the chunk
                # in progress first, so the download is still running for a while after the failure.
                deadline = time.monotonic() + 3
                while not channel.is_cancelled(request_id) and time.monotonic() < deadline:
                    time.sleep(0.01)
                time.sleep(self.fake["chunk_delay"])
                break
            live = self.fake["live_every"] > 0 and number % self.fake["live_every"] == 0
            needed = [path] + ([os.path.splitext(path)[0] + ".MOV"] if live else [])
            missing = [item for item in needed if not os.path.exists(item)]
            sidecar = path + ".xmp"
            if not missing:
                counts["skipped"] += 1
                files = needed + ([sidecar] if request.get("xmp") and os.path.exists(sidecar) else [])
                channel.send({**base, "event": "skipped", "path": path, "paths": needed, "files": files})
            else:
                if self.fake["throttle_after"] is not None and self.downloaded >= self.fake["throttle_after"]:
                    self.end(request_id, {"id": request_id, "event": "error", "kind": THROTTLE_KIND,
                                          "message": THROTTLE_MESSAGE})
                    return
                written = []
                stopped = False
                failed_movie = False
                for item in missing:
                    if item.endswith(".MOV") and number == self.fake["movie_fails_at"]:
                        failed_movie = True
                        break
                    if not self.write_item(request_id, item, number):
                        stopped = True
                        break
                    written.append(item)
                if stopped:
                    break
                if failed_movie:
                    counts["failed"] += 1
                    channel.send({**base, "event": "failed", "reason": "ConnectionError: the movie didn't download",
                                  "paths": written})
                else:
                    if request.get("xmp"):
                        with open(sidecar, "w", encoding="utf-8") as handle:
                            handle.write("<x:xmpmeta/>\n")
                    self.downloaded += 1
                    counts["downloaded"] += 1
                    files = needed + ([sidecar] if request.get("xmp") else [])
                    channel.send({**base, "event": "downloaded", "path": written[0] if written else path,
                                  "paths": written, "files": files})
            done += 1
            channel.send({"id": request_id, "event": "progress", "done": done, "total": len(chosen)})
            if not self.fake["stuck"]:
                self.serve_waiting()
            if rate > 0:
                wait = started + (position + 1) / rate - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
        cancelled = channel.is_cancelled(request_id)
        self.end(request_id, {"id": request_id, "event": "done", "cancelled": cancelled, **counts})


def main(argv):
    fake = parse(argv)
    if fake["launch_log"]:
        with open(fake["launch_log"], "a") as handle:
            handle.write(f"{os.getpid()} bridge\n")
    order, trash = load_library(fake)
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    channel = Channel(protocol)
    threading.Thread(target=channel.read, args=(sys.stdin,), daemon=True).start()

    sys.stderr.write("fake bridge: Authenticating...\n")
    time.sleep(fake["auth_delay"])
    sys.stderr.write("fake bridge: Authentication completed successfully\n")
    channel.send({"event": "ready", "count": len(order) + fake["hidden"]})
    return Bridge(channel, fake, order, trash).serve()


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv[1:]))
