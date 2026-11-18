"""End-to-end check of sleep.html against the recorder running the fake headband (not a unit test).

    PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8799 --out /tmp/sr-rec/recordings --seconds 900
    uv run --no-project --with playwright python -I tests/web/fake_sleep_check.py --port 8799

Waits until the fake has recorded --minutes of signal (scoring needs 5), opens the Sleep page in headless Chrome
at phone size, and checks that the page starts the update by itself (POST /sleep-report runs
scripts/sleep_report.py under systemd-run), that a second POST while it runs starts nothing, that the report
renders (title, total, chart, the "i" note), and that the console stayed clean. --shot PATH saves a screenshot.
The hub writes the report into the "nights" folder next to --out (here /tmp/sr-rec/nights).
"""
import argparse, json, sys, time, urllib.request

from playwright.sync_api import sync_playwright


def get(base: str, path: str) -> dict:
    return json.loads(urllib.request.urlopen(base + path, timeout=10).read())


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--minutes", type=float, default=5.5, help="recorded signal to wait for before opening the page")
    ap.add_argument("--timeout", type=float, default=600, help="seconds to wait for the report")
    ap.add_argument("--chrome", default="/usr/bin/google-chrome")
    ap.add_argument("--shot")
    a = ap.parse_args()
    base = f"http://127.0.0.1:{a.port}/"  # not localhost: Chrome on this laptop tries [::1] first, and after a
    # recorder restart each request then waits ~20 s for an IPv6 answer that never comes
    while (m := get(base, "state")["minutes"]) < a.minutes:
        print(f"recorded {m} min, waiting for {a.minutes}", flush=True)
        time.sleep(20)
    problems: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=a.chrome, headless=True)
        page = browser.new_page(viewport={"width": 390, "height": 844}, device_scale_factor=2)
        page.on("console", lambda m: m.type in ("error", "warning") and problems.append(f"console {m.type}: {m.text}"))
        page.on("pageerror", lambda e: problems.append(f"page error: {e}"))
        page.on("requestfailed", lambda r: problems.append(f"request failed: {r.url}"))
        page.goto(base + "sleep.html")
        page.wait_for_selector("#busy:not(.hidden)", timeout=20_000)
        busy = page.inner_text("#busy")
        req = urllib.request.Request(base + "sleep-report", data=b"", method="POST")
        again = json.loads(urllib.request.urlopen(req, timeout=10).read())
        steps, t0 = set(), time.time()
        while time.time() - t0 < a.timeout and page.is_visible("#busy"):
            steps.add(page.inner_text("#step").split(" · ")[0])
            time.sleep(1)
        page.wait_for_selector("#nights section h2", timeout=10_000)
        img_ok = page.evaluate("[...document.images].every(i => i.complete && i.naturalWidth > 0)")
        n_img = page.evaluate("document.images.length")
        text = page.inner_text("main")
        if a.shot:
            page.screenshot(path=a.shot, full_page=True)
        page.click("#title .ev-i")
        note = page.inner_text("#ev-title")
        browser.close()
    st = get(base, "sleep-report")
    checks = {
        "page said it is scoring": "Scoring your sleep" in busy,
        "second POST started nothing": again.get("running") is True and again.get("started") is False,
        "job finished without failing": not st["running"] and "failed" not in st and st["report"] is not None,
        "up to date afterwards": not st["stale"],
        "night title shown": "Night of" in text,
        "honest note shown": "not yet validated on this headband" in text,
        "chart images loaded": img_ok and n_img >= (1 if st["report"] and st["report"]["hypnogram"] else 0),
        "i opens the sleep-scoring note": note.startswith("Sleep scoring"),
        "no console errors": not problems,
    }
    print(json.dumps(dict(checks=checks, steps=sorted(steps), problems=problems, images=n_img,
                          seconds=round(time.time() - t0), text=text), indent=1))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
