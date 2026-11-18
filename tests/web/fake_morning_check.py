"""End-to-end check of morning.html's automatic result against the fake headband (not a unit test).

The contact step restarts the recorder, so run the fake recorder in a restart loop like record_night.sh does:

    while :; do PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8799 \\
        --out /tmp/sr-rec/recordings --seconds 1500; [ $? = 3 ] || break; sleep 2; done
    uv run --no-project --with playwright python -I tests/web/fake_morning_check.py --port 8799

Goes through morning.html?short=1 in headless Chrome at phone size (contact, 60 s eyes closed, 60 s eyes open,
ratings 5 / 3 / 2, Save) and checks that the Saved screen works the result out by itself (POST /morning-report runs
scripts/morning_check.py), shows the plain numbers and the ratings, hides the laptop command, and that the console
stayed clean. The fake's alpha is strong in even minutes, so the eyes-closed rise can come out either way.
"""
import argparse, json, sys, time

from playwright.sync_api import sync_playwright


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--chrome", default="/usr/bin/google-chrome")
    ap.add_argument("--shot")
    a = ap.parse_args()
    base = f"http://127.0.0.1:{a.port}/"  # not localhost: Chrome on this laptop tries [::1] first, and after a
    # recorder restart each request then waits ~20 s for an IPv6 answer that never comes
    problems: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=a.chrome, headless=True,
                                    args=["--autoplay-policy=no-user-gesture-required"])
        page = browser.new_page(viewport={"width": 390, "height": 844}, device_scale_factor=2)
        page.on("console", lambda m: m.type in ("error", "warning") and problems.append(f"console {m.type}: {m.text}"))
        page.on("pageerror", lambda e: problems.append(f"page error: {e}"))
        page.goto(base + "morning.html?short=1")
        page.click("#go")
        page.wait_for_selector("#begin:not([disabled])", timeout=180_000)  # the recorder restarts for contact
        page.click("#begin")
        page.wait_for_selector("#rate:not(.hidden)", timeout=200_000)  # 60 s closed + 60 s open
        for scale, v in (("kss", 5), ("mood", 3), ("tension", 2)):
            page.click(f"#{scale} button[data-v='{v}']")
        page.click("#save")
        page.wait_for_selector("#done:not(.hidden)", timeout=10_000)
        working = page.inner_text("#dsay")
        t0 = time.time()
        page.wait_for_function("document.querySelectorAll('#result .mr-row').length > 0 || "
                               "!document.getElementById('dcmd').classList.contains('hidden')", timeout=200_000)
        seconds = round(time.time() - t0)
        text = page.inner_text("#done")
        cmd_hidden = page.eval_on_selector("#dcmd", "e => e.classList.contains('hidden')")
        if a.shot:
            page.screenshot(path=a.shot, full_page=True)
        page.goto(base + "sleep.html")  # the Sleep page shows the newest morning result too
        page.wait_for_selector("#morning .mr-row", timeout=20_000)
        sleep_text = page.inner_text("#morning")
        browser.close()
    checks = {
        "said it is working it out": "Working it out" in working,
        "plain numbers shown": all(w in text for w in ("Alpha strength, eyes closed", "Alpha speed", "1/f slope",
                                                       "Clean data", "Eyes-closed rise")),
        "ratings shown": "5 of 9" in text and "3 of 5" in text and "2 of 5" in text,
        "laptop command hidden": cmd_hidden,
        "sleep page shows it": "Morning check-in" in sleep_text and "5 of 9" in sleep_text,
        # the contact step restarts the recorder: "connection refused" while it is away is expected
        "no console errors": not [x for x in problems if "ERR_CONNECTION_REFUSED" not in x],
    }
    print(json.dumps(dict(checks=checks, seconds=seconds, problems=problems, text=text), indent=1, ensure_ascii=False))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
