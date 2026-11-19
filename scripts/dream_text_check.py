"""The dream catcher's speech to text on the laptop: the phone's engine and models on spoken test clips.

Makes clips with a text-to-speech voice (no personal audio: dream-like sentences in Russian and English, two voices
each), once clear and once "sleepy" (slower, quiet, muffled, with room hiss and silence around it, as a 16 kHz
answer from the phone on the pillow), plus room hiss with no voice. Then transcribes every clip with each pipeline
and prints the word error rate per language and condition, the clips where words were invented from silence, and
the time per second of audio. DECISIONS rows 250-259.

    # 1. the clips (Piper, GPL: a laptop-only test tool, never in the app or the lock file)
    uv run --no-project --with piper-tts==1.8.0 --with numpy python scripts/dream_text_check.py clips --models _local/stt
    # 2. the check (sherpa-onnx 2.0.1, the phone's engine)
    UV_PROJECT_ENVIRONMENT=$PWD/_local/stt/venv \
        uv run --project analysis --only-group stt python scripts/dream_text_check.py check --models _local/stt

`--models` holds the downloaded models (README "Dream catcher: speech to text"): `parakeet-v3/`, `whisper-small/`,
`whisper-base/`, `vad/silero_vad.onnx` and the Piper voices under `tts/`. Clips and results go to `<models>/check/`
(git-ignored with `_local/`).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import wave
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:
    import sherpa_onnx as so

RATE = 16000
SEED = 20261119

# Dream-like answers, invented for the test (nothing personal).
SENTENCES = {
    "ru": [
        "Я видел дерево, которое росло прямо из воды.",
        "Там была какая-то лестница, и она уходила в облака.",
        "Мне казалось, что я плыву по реке на старом диване.",
        "Бабушка стояла на кухне и пекла пироги с вишней.",
        "Какие-то цифры падали с неба, как снег.",
        "Я думал о том, что надо завтра купить хлеб.",
        "Синяя птица сидела на окне и что-то говорила.",
        "Я шёл по длинному коридору, а двери всё не кончались.",
        "Кажется, я разговаривал с котом про погоду.",
        "Ничего особенного, просто темно и тепло.",
    ],
    "en": [
        "I saw a tree growing right out of the water.",
        "There was a staircase going up into the clouds.",
        "I was floating down a river on an old sofa.",
        "My grandmother was baking cherry pies in the kitchen.",
        "Numbers were falling from the sky like snow.",
        "I was thinking that I need to buy bread tomorrow.",
        "A blue bird sat on the window and said something.",
        "I was walking down a long hallway and the doors never ended.",
        "I think I was talking to a cat about the weather.",
        "Nothing special, just dark and warm.",
    ],
}
VOICES = {
    "ru": ["vits-piper-ru_RU-irina-medium", "vits-piper-ru_RU-dmitri-medium"],
    "en": ["vits-piper-en_US-ryan-medium", "vits-piper-en_GB-alan-medium"],
}


@dataclass(frozen=True)
class Clip:
    name: str
    lang: str  # "ru", "en" or "" (no voice)
    condition: str  # "clear", "sleepy" or "silence"
    text: str
    samples: np.ndarray  # float32, 16 kHz


def db(x: float) -> float:
    return float(10 ** (x / 20))


def resample(x: np.ndarray, rate: int) -> np.ndarray:
    if rate == RATE:
        return x.astype(np.float32)
    # a short low-pass first (the TTS runs at 22.05 kHz), then linear interpolation onto 16 kHz
    k = np.hanning(9)
    x = np.convolve(x, k / k.sum(), mode="same")
    t = np.arange(int(len(x) * RATE / rate)) * rate / RATE
    return np.interp(t, np.arange(len(x)), x).astype(np.float32)


def hiss(n: int, rms_db: float, rng: np.random.Generator) -> np.ndarray:
    """Room noise: white noise tilted toward low frequencies, at the given RMS (dBFS)."""
    w = rng.standard_normal(n + 64)
    pink = np.convolve(w, np.exp(-np.arange(64) / 8.0), mode="valid")[:n]
    return (pink / np.sqrt(np.mean(pink**2)) * db(rms_db)).astype(np.float32)


def sleepy(voice: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """A muffled, quiet answer from a phone on the pillow: low-passed, -36 dBFS RMS, room hiss at -62 dBFS,
    1.5 s before and 3 s after (the recorder stops after 3 s of quiet)."""
    k = np.hanning(11)
    v = np.convolve(voice, k / k.sum(), mode="same")
    v = v / np.sqrt(np.mean(v[np.abs(v) > 0.01 * np.abs(v).max()] ** 2)) * db(-36)
    x = np.concatenate([np.zeros(int(1.5 * RATE)), v, np.zeros(3 * RATE)])
    return (x + hiss(len(x), -62, rng)).astype(np.float32)


def clear(voice: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    v = voice / np.abs(voice).max() * db(-12)
    x = np.concatenate([np.zeros(RATE // 2), v, np.zeros(RATE)])
    return (x + hiss(len(x), -72, rng)).astype(np.float32)


def make_clips(models: Path) -> list[Clip]:
    from piper import PiperVoice, SynthesisConfig  # noqa: PLC0415 (only the clips step has Piper)

    rng = np.random.default_rng(SEED)
    clips: list[Clip] = []
    for lang, voices in VOICES.items():
        for vname in voices:
            d = models / "tts" / f"{vname}.x" / vname
            voice = PiperVoice.load(str(next(d.glob("*.onnx"))))
            for condition, length in (("clear", 1.0), ("sleepy", 1.35)):
                for i, text in enumerate(SENTENCES[lang]):
                    chunks = list(voice.synthesize(text, syn_config=SynthesisConfig(length_scale=length)))
                    raw = np.concatenate([c.audio_float_array for c in chunks]).astype(np.float64)
                    v = resample(raw, chunks[0].sample_rate)
                    x = clear(v, rng) if condition == "clear" else sleepy(v, rng)
                    clips.append(Clip(f"{lang}-{vname.split('-')[3]}-{condition}-{i + 1:02d}", lang, condition, text, x))
    for i in range(6):
        clips.append(Clip(f"silence-{i + 1:02d}", "", "silence", "", hiss(10 * RATE, -62, rng)))
    return clips


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        if w.getframerate() != RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f"{path}: not 16 kHz mono 16-bit")
        return (np.frombuffer(w.readframes(w.getnframes()), dtype="<i2") / 32768).astype(np.float32)


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


# ---- the phone's pipeline (app/lib/dream/speech.dart): level, voice detector, recognizer ----

GAIN_MAX_DB = 30.0
PEAK_DB = -3.0


def level(x: np.ndarray) -> np.ndarray:
    """Raises a quiet answer so its peak is at -3 dBFS (at most +30 dB); never lowers it."""
    peak = float(np.abs(x).max()) if len(x) else 0.0
    if peak <= 0:
        return x
    gain = min(db(PEAK_DB) / peak, db(GAIN_MAX_DB))
    return (x * max(gain, 1.0)).astype(np.float32)


PAD_S = 0.25


def voiced(x: np.ndarray, vad_path: Path, pad_s: float = 0.0) -> np.ndarray:
    """The parts with a voice (Silero), each widened by `pad_s` on both sides (overlaps merged), joined with 0.3 s
    of silence between them; empty when there is none."""
    cfg = so.VadModelConfig(
        silero_vad=so.SileroVadModelConfig(
            model=str(vad_path), threshold=0.4, min_silence_duration=0.5, min_speech_duration=0.25,
            max_speech_duration=30,
        ),
        sample_rate=RATE,
        num_threads=1,
    )
    vad = so.VoiceActivityDetector(cfg, buffer_size_in_seconds=60)
    window = cfg.silero_vad.window_size
    padded = np.concatenate([x, np.zeros(window, dtype=np.float32)])
    for i in range(0, len(padded) - window + 1, window):
        vad.accept_waveform(padded[i : i + window])
    vad.flush()
    spans: list[list[int]] = []
    pad = int(pad_s * RATE)
    while not vad.empty():
        a, n = vad.front.start, len(vad.front.samples)
        vad.pop()
        lo, hi = max(0, a - pad), min(len(x), a + n + pad)
        if spans and lo <= spans[-1][1]:
            spans[-1][1] = max(spans[-1][1], hi)
        else:
            spans.append([lo, hi])
    gap = np.zeros(int(0.3 * RATE), dtype=np.float32)
    parts = [p for lo, hi in spans for p in (x[lo:hi], gap)]
    return np.concatenate(parts) if parts else np.zeros(0, dtype=np.float32)


@dataclass
class Pipeline:
    name: str
    make: Callable[[str], so.OfflineRecognizer]  # language ("" = detect) -> recognizer
    use_vad: bool
    fixed_lang: bool = False
    pad_s: float = 0.0


def whisper(d: Path, size: str) -> Callable[[str], so.OfflineRecognizer]:
    def make(lang: str) -> so.OfflineRecognizer:
        return so.OfflineRecognizer.from_whisper(
            encoder=str(d / f"{size}-encoder.int8.onnx"),
            decoder=str(d / f"{size}-decoder.int8.onnx"),
            tokens=str(d / f"{size}-tokens.txt"),
            language=lang,
            num_threads=4,
        )

    return make


def parakeet(d: Path) -> Callable[[str], so.OfflineRecognizer]:
    def make(_: str) -> so.OfflineRecognizer:
        return so.OfflineRecognizer.from_transducer(
            encoder=str(d / "encoder.int8.onnx"),
            decoder=str(d / "decoder.int8.onnx"),
            joiner=str(d / "joiner.int8.onnx"),
            tokens=str(d / "tokens.txt"),
            num_threads=4,
            model_type="nemo_transducer",
        )

    return make


def norm(s: str) -> list[str]:
    s = s.lower().replace("ё", "е")
    s = re.sub(r"[^\w\s']", " ", s)
    return s.split()


def edits(ref: list[str], hyp: list[str]) -> int:
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[len(hyp)]


def run(p: Pipeline, clips: list[Clip], vad_path: Path) -> dict[str, object]:
    recs: dict[str, so.OfflineRecognizer] = {}
    t_load = time.perf_counter()
    recs[""] = p.make("")
    load_s = time.perf_counter() - t_load
    rows = []
    compute = audio = 0.0
    for c in clips:
        lang = c.lang if p.fixed_lang and c.lang else ""
        if lang not in recs:
            recs[lang] = p.make(lang)
        t0 = time.perf_counter()
        x = level(c.samples)
        if p.use_vad:
            x = voiced(x, vad_path, p.pad_s)
        text = ""
        if len(x) >= int(0.2 * RATE):
            s = recs[lang].create_stream()
            s.accept_waveform(RATE, x)
            recs[lang].decode_stream(s)
            text = s.result.text.strip()
        compute += time.perf_counter() - t0
        audio += len(c.samples) / RATE
        ref, hyp = norm(c.text), norm(text)
        rows.append({"clip": c.name, "lang": c.lang, "condition": c.condition, "ref": c.text, "hyp": text,
                     "edits": edits(ref, hyp), "words": len(ref)})
    out: dict[str, object] = {"pipeline": p.name, "load_s": round(load_s, 2), "rtf": round(compute / audio, 3),
                              "rows": rows}
    for lang in ("ru", "en"):
        for cond in ("clear", "sleepy"):
            sel = [r for r in rows if r["lang"] == lang and r["condition"] == cond]
            out[f"wer_{lang}_{cond}"] = round(100 * sum(r["edits"] for r in sel) / sum(r["words"] for r in sel), 1)
    out["invented"] = sum(1 for r in rows if r["condition"] == "silence" and r["hyp"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=["clips", "check"])
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--only", nargs="*", help="pipelines to run (default: all)")
    a = ap.parse_args()
    m: Path = a.models
    out = m / "check"
    (out / "clips").mkdir(parents=True, exist_ok=True)
    if a.step == "clips":
        clips = make_clips(m)
        for c in clips:
            write_wav(out / "clips" / f"{c.name}.wav", c.samples)
        manifest = [{"name": c.name, "lang": c.lang, "condition": c.condition, "text": c.text} for c in clips]
        (out / "clips.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1))
        print(f"{len(clips)} clips, {sum(len(c.samples) for c in clips) / RATE:.0f} s of audio in {out / 'clips'}")
        return 0
    global so  # noqa: PLW0603 (sherpa-onnx only in the check step)
    import sherpa_onnx as so  # noqa: PLC0415

    clips = [
        Clip(c["name"], c["lang"], c["condition"], c["text"], read_wav(out / "clips" / f"{c['name']}.wav"))
        for c in json.loads((out / "clips.json").read_text())
    ]
    print(f"{len(clips)} clips, {sum(len(c.samples) for c in clips) / RATE:.0f} s of audio", flush=True)
    pipes = [
        Pipeline("parakeet-v3 + vad", parakeet(m / "parakeet-v3"), True),
        Pipeline("parakeet-v3 + vad 0.25 s", parakeet(m / "parakeet-v3"), True, pad_s=PAD_S),
        Pipeline("parakeet-v3, whole clip", parakeet(m / "parakeet-v3"), False),
        Pipeline("whisper-small + vad, detect", whisper(m / "whisper-small", "small"), True),
        Pipeline("whisper-small + vad, language set", whisper(m / "whisper-small", "small"), True, fixed_lang=True),
        Pipeline("whisper-small, whole clip, detect", whisper(m / "whisper-small", "small"), False),
        Pipeline("whisper-base + vad, detect", whisper(m / "whisper-base", "base"), True),
    ]
    results = []
    for p in pipes:
        if a.only and not any(o in p.name for o in a.only):
            continue
        r = run(p, clips, m / "vad" / "silero_vad.onnx")
        results.append(r)
        print(
            f"{p.name:38s} WER ru {r['wer_ru_clear']:5.1f} / {r['wer_ru_sleepy']:5.1f}  "
            f"en {r['wer_en_clear']:5.1f} / {r['wer_en_sleepy']:5.1f} (clear / sleepy, %)  "
            f"invented from silence {r['invented']}/6  {r['rtf']:.3f} s per s of audio  load {r['load_s']} s",
            flush=True,
        )
    name = "results" + ("-" + "-".join(a.only).replace(" ", "_") if a.only else "") + ".json"
    (out / name).write_text(json.dumps(results, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
