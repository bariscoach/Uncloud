"""A stand-in for photo_bridge.py, for tests of the app's process handling. No network, no account.

Usage: python3 fake_bridge.py [fake options] -- -u APPLE_ID --cookie-directory DIR

Fake options:
  --total N           items in the library (default 1000), IDs "asset-0" (oldest) ...
  --rate R            downloads per second; 0 means as fast as possible (default 50)
  --auth-delay S      seconds before "ready" (default 0)
  --launch-log PATH   append "<pid> bridge" to PATH at start
  --stats-delay S     seconds per stats page of 100 items (default 0)
  --chunks N          chunks per downloaded file (default 1)
  --chunk-delay S     seconds per chunk (default 0), for slow downloads of large files
  --stuck             a download never checks for cancel or pings: the bridge looks hung
  --remove-dest-at N  in a download, the Nth item (counted from 0) finds the destination gone: the fake
                      deletes the destination folder and reports that item failed, as a vanished drive would;
                      then it waits for the cancel the app sends and finishes the chunk in progress

Speaks the bridge's JSON-lines protocol (page, count, albums, download, stats, cancel, pause, resume,
ping) closely enough for the app: "ready" after signing in, downloads write DEST/YYYY/MM files through
a ".part" file and report progress/downloaded/skipped and a final done with "cancelled"; item i is
fake_bytes(i) bytes in page and stats replies. Like the real bridge, a download checks for cancel,
pause and pings after every chunk (a cancel removes the partial file) and answers page, count,
albums and ping requests between chunks and items and while paused. Closing stdin ends it; SIGTERM,
SIGSTOP and SIGCONT keep their default meaning.
"""

import json
import os
import queue
import shutil
import signal
import sys
import threading
import time


def parse(argv):
    fake = {"total": 1000, "rate": 50.0, "auth_delay": 0.0, "launch_log": None, "stats_delay": 0.0,
            "chunks": 1, "chunk_delay": 0.0, "stuck": False, "remove_dest_at": None}
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
        else:
            index += 1
    return fake


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


def item_path(dest, index):
    year = 2001 + index // 1200
    month = 1 + (index // 100) % 12
    return os.path.join(dest, f"{year:04d}", f"{month:02d}", f"IMG_{index:06d}.JPG")


def fake_bytes(index):
    return 1000 + index


class Bridge:
    def __init__(self, channel, fake):
        self.channel = channel
        self.fake = fake
        self.total = fake["total"]
        self.deferred = []

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
            self.channel.send({"id": request_id, "event": "count", "count": total})
        elif command == "albums":
            self.channel.send({"id": request_id, "event": "albums", "albums": ["Trip"]})
        elif command == "page":
            offset = int(request.get("offset", 0))
            limit = int(request.get("limit", 200))
            items = [{"id": f"asset-{i}", "filename": f"IMG_{i:06d}.JPG", "created": None, "type": "image",
                      "size": fake_bytes(i), "bytes": fake_bytes(i), "thumbURL": None}
                     for i in range(offset, min(total, offset + limit))]
            self.channel.send({"id": request_id, "event": "page", "offset": offset, "items": items})
        elif command in ("download", "stats") and busy:
            self.deferred.append(request)
        elif command == "download":
            self.download(request)
        elif command == "stats":
            self.stats(request)
        else:
            self.channel.send({"id": request_id, "event": "error", "kind": "badRequest", "message": "unknown"})

    def stats(self, request):
        channel = self.channel
        request_id = request.get("id")
        offset = max(0, int(request.get("offset") or 0))
        total = self.total
        done = 0
        total_bytes = 0
        complete = True
        for start in range(offset, total, 100):
            sizes = {f"asset-{i}": fake_bytes(i) for i in range(start, min(total, start + 100))}
            if self.fake["stats_delay"] > 0:
                time.sleep(self.fake["stats_delay"])
            done += len(sizes)
            total_bytes += sum(sizes.values())
            channel.send({"id": request_id, "event": "statsProgress", "done": done, "total": total,
                          "bytes": total_bytes, "sizes": sizes, "unsized": []})
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
        os.replace(part, path)
        return True

    def download(self, request):
        channel = self.channel
        request_id = request.get("id")
        ids = set(request.get("ids") or [])
        everything = [f"asset-{i}" for i in range(self.total)]
        chosen = [a for a in everything if (a in ids) == (request.get("mode") == "only")]
        counts = {"downloaded": 0, "skipped": 0, "failed": 0}
        channel.send({"id": request_id, "event": "progress", "done": 0, "total": len(chosen)})
        rate = self.fake["rate"]
        started = time.monotonic()
        done = 0
        for position, asset in enumerate(chosen):
            if not self.fake["stuck"]:
                self.channel.answer_pings()
                if not self.hold(request_id):
                    break
            if channel.is_cancelled(request_id):
                break
            index = int(asset.split("-")[1])
            path = item_path(request["dest"], index)
            base = {"id": request_id, "asset": asset, "filename": os.path.basename(path)}
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
            if os.path.exists(path):
                counts["skipped"] += 1
                channel.send({**base, "event": "skipped", "path": path})
            elif self.write_item(request_id, path, index):
                counts["downloaded"] += 1
                channel.send({**base, "event": "downloaded", "path": path, "paths": [path]})
            else:
                break
            done += 1
            channel.send({"id": request_id, "event": "progress", "done": done, "total": len(chosen)})
            if not self.fake["stuck"]:
                self.serve_waiting()
            if rate > 0:
                wait = started + (position + 1) / rate - time.monotonic()
                if wait > 0:
                    time.sleep(wait)
        cancelled = channel.is_cancelled(request_id)
        with channel.lock:
            channel.cancelled.discard(request_id)
            channel.paused.discard(request_id)
        if self.fake["launch_log"]:
            # Logged when the download has really ended in the bridge, before its final reply.
            with open(self.fake["launch_log"], "a") as handle:
                handle.write(f"{os.getpid()} download-ended {request_id}\n")
        channel.send({"id": request_id, "event": "done", "cancelled": cancelled, **counts})


def main(argv):
    fake = parse(argv)
    if fake["launch_log"]:
        with open(fake["launch_log"], "a") as handle:
            handle.write(f"{os.getpid()} bridge\n")
    protocol = os.fdopen(os.dup(1), "w", encoding="utf-8", buffering=1)
    os.dup2(2, 1)
    channel = Channel(protocol)
    threading.Thread(target=channel.read, args=(sys.stdin,), daemon=True).start()

    sys.stderr.write("fake bridge: Authenticating...\n")
    time.sleep(fake["auth_delay"])
    sys.stderr.write("fake bridge: Authentication completed successfully\n")
    channel.send({"event": "ready", "count": fake["total"]})
    return Bridge(channel, fake).serve()


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv[1:]))
