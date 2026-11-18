"""End-to-end check of sound.html against the recorder running the fake headband (not a unit test).

    PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --port 8799 --out /tmp/rec --seconds 600
    uv run --no-project --with playwright python -I tests/web/fake_live_check.py --port 8799 --seconds 300 --align

Opens the page in headless Chrome, presses Start, listens, then lines the page's analysis steps up with the
fake signal exactly: the stream's sample index of the session's first sample (window.__sound.firstI) plus the
step's sample count is the fake's own sample number (eyes closed in even minutes, jaw 3 s every 45 s).
--align waits to press Start until the fake is 90 s into its 120 s cycle, so the 30 s eyes-open and 60 s
eyes-closed calibration line up with the fake's weak and strong alpha. --save PATH writes the session log
(replay it with replaySession in scripts/web/sound-source.js to check it repeats bit for bit).
"""
import argparse, json, statistics, time

from playwright.sync_api import sync_playwright

FS = 250


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--seconds", type=float, default=300)
    ap.add_argument("--no-cal", action="store_true")
    ap.add_argument("--align", action="store_true")
    ap.add_argument("--mode", default="training")
    ap.add_argument("--chrome", default="/usr/bin/google-chrome")
    ap.add_argument("--save")
    a = ap.parse_args()
    base = f"http://localhost:{a.port}/"
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=a.chrome, args=["--autoplay-policy=no-user-gesture-required"])
        page = browser.new_page(viewport={"width": 700, "height": 1000})
        errors: list[str] = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: m.type == "error" and errors.append(m.text))
        page.goto(base + f"sound.html?mode={a.mode}")
        page.wait_for_function("document.getElementById('src').value === 'live'")
        if a.align:  # the stream's next sample index is the fake's own sample number
            hello_i = page.evaluate("""() => new Promise((ok) => { const es = new EventSource('stream');
                es.onmessage = (e) => { const m = JSON.parse(e.data); if (m.hello) { es.close(); ok(m.next_i); } }; })""")
            fake_t = hello_i / FS
            wait = ((90 - fake_t % 120) + 120) % 120
            print(f"waiting {wait:.0f} s to line up with the fake signal", flush=True)
            time.sleep(wait)
        page.click("#go2" if a.no_cal else "#go")
        for s in range(0, int(a.seconds), 30):
            time.sleep(min(30, a.seconds - s))
            print(f"{min(a.seconds, s + 30):.0f} s: {page.text_content('#say')} / {page.text_content('#why')}", flush=True)
        log = page.evaluate("() => ({ steps: window.__sound.steps, bells: window.__sound.bells, cues: window.__sound.cues, firstI: window.__sound.firstI, lags: window.__sound.lags })")
        session = page.evaluate("() => window.__sound.session()")
        page.click("#stop")
        time.sleep(2)
        browser.close()
    if a.save:
        with open(a.save, "w") as f:
            json.dump(session, f)

    first = log["firstI"]
    fake = lambda n: (first + n) / FS  # noqa: E731  fake time of the sample that ends a step
    closed = lambda ft: int(ft // 60) % 2 == 0  # noqa: E731
    run = [s for s in log["steps"] if s["quality"] == "good" and s["z"] is not None]
    settled = [s for s in run if fake(s["n"]) % 60 > 4]
    z_closed = [s["z"] for s in settled if closed(fake(s["n"]))]
    z_open = [s["z"] for s in settled if not closed(fake(s["n"]))]
    jaw = [s for s in log["steps"] if 0.5 < fake(s["n"]) % 45 < 3 and s["quality"] == "good"]
    bells = [fake(b["n"]) for b in log["bells"]]
    bad = [ft for ft in bells if ft % 45 < 3 + 4 or not closed(ft - 3)]
    cal = next((ln for ln in session["lines"] if ln["type"] == "calibration"), None)
    out = dict(calibrate=not a.no_cal, mode=a.mode, steps=len(log["steps"]), run_steps=len(run), cues=log["cues"],
               calibration=cal and {k: cal[k] for k in ("iaf", "alpha", "line", "sd", "rise", "cleanS")},
               z_eyes_closed=round(statistics.mean(z_closed), 2) if z_closed else None,
               z_eyes_open=round(statistics.mean(z_open), 2) if z_open else None,
               jaw_steps=len(jaw), bells_allowed_in_jaw=sum(1 for s in jaw if s["bellsAllowed"]),
               bells=len(bells), bell_fake_times=[round(b, 1) for b in bells], bells_near_jaw_or_eyes_open=len(bad),
               stream_lag_ms_median=round(statistics.median(log["lags"])) if log["lags"] else None,
               audio=session["info"], errors=errors)
    print(json.dumps(out, indent=1))
    ok = (not errors and not bad and all(not s["bellsAllowed"] for s in jaw) and len(run) > 0
          and (not z_closed or not z_open or statistics.mean(z_closed) > statistics.mean(z_open) + 2))
    print("PASS" if ok else "FAIL")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
