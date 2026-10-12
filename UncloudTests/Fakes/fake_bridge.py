"""A stand-in for photo_bridge.py, for tests of the app's process handling. No network, no account.

Usage: python3 fake_bridge.py [fake options] -- -u APPLE_ID --cookie-directory DIR

Fake options:
  --total N           items in the library (default 1000), IDs "asset-0" (oldest) ...
  --rate R            downloads per second; 0 means as fast as possible (default 50)
  --auth-delay S      seconds before "ready" (default 0)
  --launch-log PATH   append "<pid> bridge" to PATH at start

Speaks the bridge's JSON-lines protocol (page, count, albums, download, cancel) closely enough
for the app: "ready" after signing in, downloads write DEST/YYYY/MM files and report
progress/downloaded/skipped and a final done with "cancelled". Closing stdin ends it; SIGTERM,
SIGSTOP and SIGCONT keep their default meaning.
"""

import json
import os
import queue
import signal
import sys
import threading
import time


def parse(argv):
    fake = {"total": 1000, "rate": 50.0, "auth_delay": 0.0, "launch_log": None}
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
        elif flag == "--launch-log":
            fake["launch_log"] = own[index + 1]; index += 2
        else:
            index += 1
    return fake


class Channel:
    def __init__(self, out):
        self.out = out
        self.lock = threading.Lock()
        self.requests = queue.Queue()
        self.cancelled = set()
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
            if message.get("cmd") == "cancel":
                self.cancelled.add(message.get("target"))
            else:
                self.requests.put(message)
        self.closed.set()
        self.requests.put(None)


def item_path(dest, index):
    year = 2001 + index // 1200
    month = 1 + (index // 100) % 12
    return os.path.join(dest, f"{year:04d}", f"{month:02d}", f"IMG_{index:06d}.JPG")


def download(channel, request, total, rate):
    request_id = request.get("id")
    ids = set(request.get("ids") or [])
    everything = [f"asset-{i}" for i in range(total)]
    chosen = [a for a in everything if (a in ids) == (request.get("mode") == "only")]
    counts = {"downloaded": 0, "skipped": 0, "failed": 0}
    channel.send({"id": request_id, "event": "progress", "done": 0, "total": len(chosen)})
    started = time.monotonic()
    done = 0
    for position, asset in enumerate(chosen):
        if channel.closed.is_set() or request_id in channel.cancelled:
            break
        index = int(asset.split("-")[1])
        path = item_path(request["dest"], index)
        base = {"id": request_id, "asset": asset, "filename": os.path.basename(path)}
        if os.path.exists(path):
            counts["skipped"] += 1
            channel.send({**base, "event": "skipped", "path": path})
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".part", "wb") as handle:
                handle.write(f"photo {index}\n".encode())
            os.replace(path + ".part", path)
            counts["downloaded"] += 1
            channel.send({**base, "event": "downloaded", "path": path, "paths": [path]})
        done += 1
        channel.send({"id": request_id, "event": "progress", "done": done, "total": len(chosen)})
        if rate > 0:
            wait = started + (position + 1) / rate - time.monotonic()
            if wait > 0:
                time.sleep(wait)
    cancelled = channel.closed.is_set() or request_id in channel.cancelled
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
    total = fake["total"]
    channel.send({"event": "ready", "count": total})
    while True:
        request = channel.requests.get()
        if request is None:
            return 0
        command = request.get("cmd")
        request_id = request.get("id")
        if command == "count":
            channel.send({"id": request_id, "event": "count", "count": total})
        elif command == "albums":
            channel.send({"id": request_id, "event": "albums", "albums": ["Trip"]})
        elif command == "page":
            offset = int(request.get("offset", 0))
            limit = int(request.get("limit", 200))
            items = [{"id": f"asset-{i}", "filename": f"IMG_{i:06d}.JPG", "created": None, "type": "image", "size": 10, "thumbURL": None}
                     for i in range(offset, min(total, offset + limit))]
            channel.send({"id": request_id, "event": "page", "offset": offset, "items": items})
        elif command == "download":
            download(channel, request, total, fake["rate"])
        else:
            channel.send({"id": request_id, "event": "error", "kind": "badRequest", "message": "unknown"})


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv[1:]))
