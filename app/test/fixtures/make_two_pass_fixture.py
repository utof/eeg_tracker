"""Makes the fixture for the two-pass test in app/test/sleep_two_pass_test.dart: what the reference two-pass scorer
(analysis/two_pass.py) does with the app's real models (run 1) on a small synthetic night, so the Dart scorer
(app/lib/sleep/model.dart) is checked against it without ONNX Runtime, which cannot run in `flutter test`.

usage (from the repo root):
  uv run --project analysis --group onnx python app/test/fixtures/make_two_pass_fixture.py

The night: 64 epochs whose samples are signal(t, c) below (exact in float32 in Dart too), cut into the pieces of
two_pass.pieces(64, piece=16, context=16): four pieces on the 16-epoch grid. Writes app/test/fixtures/two_pass/:
  expected.json: the pieces, the inputs each model call gets, the probabilities and stages; and the pieces of the
                 phone's real plan for some night lengths;
  outputs.bin:   float32 little-endian, what the model returned: per piece its pass-1 `sums` (4 x 1037) and
                 `counts` (1037), then per piece its pass-2 `logits` (epochs x 5), then the night's means (4 x 1037).
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "analysis"))
import two_pass as tp  # noqa: E402

OUT = Path(__file__).resolve().parent / "two_pass"
N_EP, PIECE, CONTEXT = 64, 16, 16
PLAN_LENGTHS = [1, 10, 175, 176, 200, 255, 256, 257, 300, 1000, 1549, 1680]


def signal(n_ep: int) -> np.ndarray:
    """(4, samples): ((37 t + 1013 c) mod 997 - 498) / 128, a scrambled ramp in about +-3.9 (the scaled range)."""
    t = np.arange(n_ep * tp.EPOCH_SAMPLES, dtype=np.int64)[None]
    c = np.arange(4, dtype=np.int64)[:, None]
    return (((37 * t + 1013 * c) % 997 - 498) / 128).astype(np.float32)


def make(models: Path = ROOT / "app" / "assets" / "models") -> tuple[dict, np.ndarray]:
    sess = tp.sessions([models / "anysleep-run1.onnx"], threads=2)[0]
    x = signal(N_EP)
    plan = tp.pieces(N_EP, PIECE, CONTEXT)
    blobs, calls = [], []
    for w0, w1, c0, c1 in plan:
        _, s, c = sess.run(None, tp.feeds(tp.window(x, w0, w1), keep=(c0 - w0, c1 - w0)))
        blobs += [s.ravel(), c.ravel()]
        calls.append(dict(w0=w0, w1=w1, c0=c0, c1=c1, keep=[c0 - w0, c1 - w0]))
    means = tp.night_means(sess, x, plan)
    for w0, w1, _, _ in plan:
        blobs.append(sess.run(["logits"], tp.feeds(tp.window(x, w0, w1), means=means))[0].ravel())
    blobs.append(means.ravel())
    probs = tp.probabilities([sess], x, N_EP, plan)
    stages = [["W", "N1", "N2", "N3", "R"][i] for i in probs.argmax(1)]
    meta = dict(epochs=N_EP, piece=PIECE, context=CONTEXT, means_width=tp.MEANS_WIDTH, pieces=calls,
                probabilities=[[round(float(v), 9) for v in row] for row in probs], stages=stages,
                plans={str(n): [list(p) for p in tp.pieces(n)] for n in PLAN_LENGTHS})
    return meta, np.concatenate(blobs).astype("<f4")


def main() -> None:
    meta, blob = make()
    OUT.mkdir(exist_ok=True)
    (OUT / "expected.json").write_text(json.dumps(meta) + "\n")
    blob.tofile(OUT / "outputs.bin")
    print(f"{len(meta['pieces'])} pieces, {blob.size * 4 / 1e3:.0f} kB of outputs, stages {''.join(s[0] for s in meta['stages'])}")


if __name__ == "__main__":
    main()
