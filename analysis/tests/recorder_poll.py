"""Watch recorder subprocesses through their live-check pages, for the end-to-end tests.

One thread per recorder, so a slow answer from one never makes the poll miss a short-lived status of another.
A request that times out is not a failure of the recorder: on a loaded laptop (a long suite running next to this
one) a page answer can take seconds. Only a refused connection after the page was up counts as the server going
away. All deadlines are generous; the loop ends as soon as every recorder has exited.
"""
import json
import subprocess
import threading
import time
import urllib.request

REQUEST_S = 15.0  # one HTTP request; far above any answer time, so a stall on a starved machine is not an error
GIVE_UP_S = 180.0  # whole watch: a recorder still running after this is killed and its test fails with its output


def get(port: int, path: str) -> dict:
    return json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/{path}", timeout=REQUEST_S).read())


def hello(port: int) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/stream", timeout=REQUEST_S) as r:
        for raw in r:
            line = raw.decode().strip()
            if line.startswith("data: "):
                return json.loads(line[6:])
    return {}


def _watch(proc: subprocess.Popen, port: int, seen: dict, end: float) -> None:
    while proc.poll() is None and time.time() < end:
        try:
            st = get(port, "state")
        except ConnectionRefusedError:
            if seen["status"]:
                seen["errors_after_up"] += 1  # the page was up and now nothing listens
        except (OSError, ValueError):
            pass  # timed out or cut off while the machine is busy; ask again
        else:
            if not seen["status"] or seen["status"][-1] != st["status"]:
                seen["status"].append(st["status"])
            if st["data"][0] and seen["hello"] is None:
                try:
                    seen["state"], seen["hello"] = st, hello(port)
                    req = urllib.request.Request(f"http://127.0.0.1:{port}/marker", data=b"test-marker", method="POST")
                    seen["marker"] = urllib.request.urlopen(req, timeout=REQUEST_S).read() == b"ok"
                except (OSError, ValueError):
                    seen["state"] = seen["hello"] = None  # try the whole first look again
        time.sleep(0.1)


def watch(procs: dict[str, subprocess.Popen], ports: dict[str, int], names: tuple[str, ...] | None = None,
          give_up_s: float = GIVE_UP_S) -> dict[str, dict]:
    """Poll `names` (default all) until every recorder has exited, then terminate any left over.

    Returns, per name: status (every distinct status seen, in order), state and hello (the first look once data
    flowed), marker (the test marker was accepted), errors_after_up (refused connections after the page was up)."""
    names = names or tuple(procs)
    seen = {n: dict(status=[], state=None, hello=None, marker=False, errors_after_up=0) for n in names}
    end = time.time() + give_up_s
    threads = [threading.Thread(target=_watch, args=(procs[n], ports[n], seen[n], end), daemon=True) for n in names]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for p in procs.values():  # a recorder that is not watched (the probe) still gets to finish
        try:
            p.wait(max(0.0, end - time.time()))
        except subprocess.TimeoutExpired:
            pass
        if p.poll() is None:
            p.terminate()
            p.wait(10)
    return seen
