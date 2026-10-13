"""A stand-in for icloudpd, for tests of the app's process handling. No network, no account.

Usage: python3 fake_icloudpd.py [fake options] -- <icloudpd arguments>
Everything up to "--" configures the fake; the rest is what the app passes to icloudpd.

Fake options:
  --total N             items in the library (default 100)
  --rate R              items per second; 0 means as fast as possible (default 50)
  --prepare-delay S     seconds of "signing in" before the total is announced (default 0)
  --child               start a child process that lives as long as this one, like PyInstaller's bootloader
  --child-ignores-term  the child ignores SIGTERM, so only SIGKILL stops it
  --launch-log PATH     append "<pid> <args>" to PATH at start
  --term-delay S        on SIGTERM, keep running S seconds before exiting (status 143), like a slow
                        shutdown; with --launch-log, append "<pid> exited" right before exiting
  --throttle-after N    after downloading N new items, log Apple's 503 throttle line, "Apple iCloud is
                        temporary refusing to serve icloudpd", and exit with status 1, as icloudpd does
  --throttle-level L    the level of that line: INFO (icloudpd's own) or ERROR (default INFO)
  --throttle-message M  log M instead, such as an error the app doesn't retry
  --throttle-runs K     throttle only the first K runs (default: every run); needs --throttle-state
  --throttle-state PATH counts the throttled runs across launches
  --live-every K        item numbers divisible by K (K > 0) are Live Photos: IMG_NNNNNN.JPG plus IMG_NNNNNN.MOV,
                        each reported on its own line, as icloudpd does
  --same-name-every K   item numbers with N % K == 1 (K > 1) get item N-1's file name, every photo is exactly
                        1000 + N bytes, and a name taken by a file of another size gets the size added
                        (icloudpd's name-size-dedup-with-suffix), as in fake_bridge.py
With icloudpd's --folder-structure none, files go directly in DEST instead of DEST/YYYY/MM.
With icloudpd's --xmp-sidecar, each photo also gets a NAME.xmp sidecar next to it (not reported).

Behaves like icloudpd where the app depends on it: log lines on stdout as
"YYYY-MM-DD HH:MM:SS LEVEL    message", "Downloading N ... to DEST ..." once, then per item
"Downloaded PATH" (INFO) or "PATH already exists" (DEBUG); files land in DEST/YYYY/MM through a
".part" file. SIGSTOP, SIGCONT and SIGTERM keep their default meaning (SIGTERM ends it with
status 143), and stdin is never read except to notice it closing.
"""

import os
import signal
import subprocess
import sys
import time


def log(level: str, message: str) -> None:
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stdout.write(f"{stamp} {level:<8} {message}\n")


def parse(argv):
    fake = {"total": 100, "rate": 50.0, "prepare_delay": 0.0, "child": False, "child_ignores_term": False,
            "launch_log": None, "term_delay": None, "throttle_after": None, "throttle_level": "INFO",
            "throttle_message": "Apple iCloud is temporary refusing to serve icloudpd",
            "throttle_runs": None, "throttle_state": None, "live_every": 0, "same_name_every": 0}
    if "--" in argv:
        split = argv.index("--")
        own, rest = argv[:split], argv[split + 1:]
    else:
        own, rest = [], argv
    index = 0
    while index < len(own):
        flag = own[index]
        if flag == "--total":
            fake["total"] = int(own[index + 1]); index += 2
        elif flag == "--rate":
            fake["rate"] = float(own[index + 1]); index += 2
        elif flag == "--prepare-delay":
            fake["prepare_delay"] = float(own[index + 1]); index += 2
        elif flag == "--launch-log":
            fake["launch_log"] = own[index + 1]; index += 2
        elif flag == "--term-delay":
            fake["term_delay"] = float(own[index + 1]); index += 2
        elif flag == "--throttle-after":
            fake["throttle_after"] = int(own[index + 1]); index += 2
        elif flag == "--throttle-level":
            fake["throttle_level"] = own[index + 1]; index += 2
        elif flag == "--throttle-message":
            fake["throttle_message"] = own[index + 1]; index += 2
        elif flag == "--throttle-runs":
            fake["throttle_runs"] = int(own[index + 1]); index += 2
        elif flag == "--throttle-state":
            fake["throttle_state"] = own[index + 1]; index += 2
        elif flag == "--live-every":
            fake["live_every"] = int(own[index + 1]); index += 2
        elif flag == "--same-name-every":
            fake["same_name_every"] = int(own[index + 1]); index += 2
        elif flag == "--child":
            fake["child"] = True; index += 1
        elif flag == "--child-ignores-term":
            fake["child"] = True; fake["child_ignores_term"] = True; index += 1
        else:
            index += 1
    real = {"dest": None, "auth_only": "--auth-only" in rest, "list_albums": "--list-albums" in rest,
            "xmp": "--xmp-sidecar" in rest, "flat": False}
    if "-d" in rest:
        real["dest"] = rest[rest.index("-d") + 1]
    if "--folder-structure" in rest:
        real["flat"] = rest[rest.index("--folder-structure") + 1] == "none"
    return fake, real


def start_child(ignores_term: bool, tag: str):
    # The tag (the launch log path) lets tests find leftover children with pgrep -f.
    code = f"# fake icloudpd child {tag}\nimport signal, time\n"
    if ignores_term:
        code += "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
    code += "time.sleep(3600)\n"
    # Same process group as this one, like the processes icloudpd's bootloader starts.
    return subprocess.Popen([sys.executable, "-I", "-c", code], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def item_path(dest: str, index: int, flat: bool = False, same_name_every: int = 0) -> str:
    number = index - 1 if same_name_every > 1 and index % same_name_every == 1 else index
    name = f"IMG_{number:06d}.JPG"
    if flat:
        path = os.path.join(dest, name)
    else:
        year = 2001 + index // 1200
        month = 1 + (index // 100) % 12
        path = os.path.join(dest, f"{year:04d}", f"{month:02d}", name)
    if same_name_every > 1:
        size = 1000 + index
        if os.path.exists(path) and os.path.getsize(path) != size:
            stem, ext = os.path.splitext(path)
            path = f"{stem}-{size}{ext}"
    return path


def slow_exit(delay: float, launch_log):
    def handler(_signum, _frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(delay)
        if launch_log:
            with open(launch_log, "a") as handle:
                handle.write(f"{os.getpid()} exited\n")
        os._exit(143)
    return handler


def throttles_this_run(fake) -> bool:
    """Whether this run stops after --throttle-after items; counts throttled runs in --throttle-state."""
    if fake["throttle_after"] is None:
        return False
    if fake["throttle_runs"] is None or not fake["throttle_state"]:
        return True
    try:
        with open(fake["throttle_state"]) as handle:
            done = int(handle.read().strip() or "0")
    except FileNotFoundError:
        done = 0
    if done >= fake["throttle_runs"]:
        return False
    with open(fake["throttle_state"], "w") as handle:
        handle.write(str(done + 1))
    return True


def main(argv) -> int:
    fake, real = parse(argv)
    if fake["launch_log"]:
        with open(fake["launch_log"], "a") as handle:
            handle.write(f"{os.getpid()} icloudpd {' '.join(argv)}\n")
    if fake["term_delay"] is not None:
        signal.signal(signal.SIGTERM, slow_exit(fake["term_delay"], fake["launch_log"]))
    child = start_child(fake["child_ignores_term"], fake["launch_log"] or "") if fake["child"] else None
    if child is not None and fake["launch_log"]:
        with open(fake["launch_log"], "a") as handle:
            handle.write(f"{child.pid} child\n")

    log("DEBUG", "Authenticating...")
    deadline = time.monotonic() + fake["prepare_delay"]
    while time.monotonic() < deadline:
        time.sleep(0.02)
    log("INFO", "Authentication completed successfully")
    if real["auth_only"]:
        return 0
    if real["list_albums"]:
        sys.stdout.write("Albums:\nFavorites\nTrip\nFamily\n")
        return 0

    dest = real["dest"] or os.getcwd()
    total = fake["total"]
    log("INFO", f"Downloading {total} original photos and videos to {dest} ...")
    rate = fake["rate"]
    throttles = throttles_this_run(fake)
    downloaded = 0
    started = time.monotonic()
    for index in range(total):
        path = item_path(dest, index, real["flat"], fake["same_name_every"])
        live = fake["live_every"] > 0 and index % fake["live_every"] == 0
        for file_path in [path] + ([os.path.splitext(path)[0] + ".MOV"] if live else []):
            if os.path.exists(file_path):
                log("DEBUG", f"{file_path} already exists")
                continue
            if throttles and downloaded >= fake["throttle_after"]:
                # Like icloudpd when Apple answers 503: it logs the exception and returns 1.
                log(fake["throttle_level"], fake["throttle_message"])
                sys.stdout.flush()
                if child is not None:
                    child.terminate()
                return 1
            if file_path == path:
                downloaded += 1
            os.makedirs(os.path.dirname(file_path), exist_ok=True)
            with open(file_path + ".part", "wb") as handle:
                content = f"photo {index}\n".encode()
                if fake["same_name_every"] > 1 and file_path == path:
                    content = content.ljust(1000 + index, b"\0")
                handle.write(content)
            os.replace(file_path + ".part", file_path)
            log("INFO", f"Downloaded {file_path}")
            if real["xmp"] and file_path == path:
                with open(path + ".xmp", "w", encoding="utf-8") as handle:
                    handle.write("<x:xmpmeta/>\n")
        if rate > 0:
            wait = started + (index + 1) / rate - time.monotonic()
            if wait > 0:
                sys.stdout.flush()
                time.sleep(wait)
    sys.stdout.flush()
    log("INFO", "All photos and videos have been downloaded")
    if child is not None:
        child.terminate()
    return 0


if __name__ == "__main__":
    # Like icloudpd: no handler of its own, so SIGTERM ends the process with status 143.
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    sys.exit(main(sys.argv[1:]))
