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
    fake = {"total": 100, "rate": 50.0, "prepare_delay": 0.0, "child": False, "child_ignores_term": False, "launch_log": None}
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
        elif flag == "--child":
            fake["child"] = True; index += 1
        elif flag == "--child-ignores-term":
            fake["child"] = True; fake["child_ignores_term"] = True; index += 1
        else:
            index += 1
    real = {"dest": None, "auth_only": "--auth-only" in rest, "list_albums": "--list-albums" in rest}
    if "-d" in rest:
        real["dest"] = rest[rest.index("-d") + 1]
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


def item_path(dest: str, index: int) -> str:
    year = 2001 + index // 1200
    month = 1 + (index // 100) % 12
    return os.path.join(dest, f"{year:04d}", f"{month:02d}", f"IMG_{index:06d}.JPG")


def main(argv) -> int:
    fake, real = parse(argv)
    if fake["launch_log"]:
        with open(fake["launch_log"], "a") as handle:
            handle.write(f"{os.getpid()} icloudpd {' '.join(argv)}\n")
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
    started = time.monotonic()
    for index in range(total):
        path = item_path(dest, index)
        if os.path.exists(path):
            log("DEBUG", f"{path} already exists")
        else:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path + ".part", "wb") as handle:
                handle.write(f"photo {index}\n".encode())
            os.replace(path + ".part", path)
            log("INFO", f"Downloaded {path}")
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
