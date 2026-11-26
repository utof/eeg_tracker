"""The monthly asking self-check (scripts/asking_check.py): the three tables, the Watch line, the days filter."""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import asking_check as ac  # noqa: E402

GOLDEN = ROOT / "packages" / "shared_labels" / "test" / "fixtures" / "confirm" / "estimates.tsv"
COLUMNS = ["start", "label", "confidence", "answer", "answered", "card", "agrees", "age_min", "why_not"]
NOW = "2026-11-24T12:00:00+03:00"


def table(tmp_path: Path, rows: list[dict[str, str]]) -> Path:
    path = tmp_path / "estimates.tsv"
    lines = ["\t".join(COLUMNS)]
    for r in rows:
        lines.append("\t".join(r.get(c, "") for c in COLUMNS))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def card(answer: str, conf: str = "0.95", label: str = "walking", **kw: str) -> dict[str, str]:
    base = {"start": "2026-11-23T10:00:00+03:00", "label": label, "confidence": conf, "answer": answer}
    return {**base, **kw}


def run(path: Path, *extra: str) -> tuple[int, str]:
    lines: list[str] = []
    code = ac.main([str(path), "--now", NOW, *extra], out=lines.append)
    return code, "\n".join(lines)


def test_table_a_bands(tmp_path: Path) -> None:
    rows = [card("yes", "0.3"), card("no", "0.3"), card("yes", "0.5"), card("yes", "0.7"), card("no", "0.9"),
            card("yes", "0.9"), card("yes", ""), card("said", "0.3", card="blind", agrees="1")]
    code, text = run(table(tmp_path, rows))
    assert code == 0
    assert "| under 0.5 | 2 | 1 | 1 | 50 |" in text
    assert "| 0.5 to 0.7 | 1 | 1 | 0 | 100 |" in text
    assert "| 0.7 to 0.9 | 1 | 1 | 0 | 100 |" in text
    assert "| 0.9 and up | 2 | 1 | 1 | 50 |" in text
    assert "| not given | 1 | 1 | 0 | 100 |" in text


def test_watch_line_appears(tmp_path: Path) -> None:
    rows = [card("yes", "0.3")] * 4 + [card("no", "0.3")] + [card("yes", "0.95")] * 4 + [card("no", "0.95")]
    _, text = run(table(tmp_path, rows))
    assert "Watch:" in text
    assert "Looks fine" not in text


def test_watch_line_absent_when_rate_falls(tmp_path: Path) -> None:
    rows = [card("no", "0.3")] * 5 + [card("yes", "0.95")] * 5
    _, text = run(table(tmp_path, rows))
    assert "Watch:" not in text
    assert "Looks fine" in text


def test_too_few_answers_to_tell(tmp_path: Path) -> None:
    rows = [card("yes", "0.3")] * 4 + [card("yes", "0.95")] * 5
    _, text = run(table(tmp_path, rows))
    assert "Watch:" not in text
    assert "Too few answers to tell" in text


def test_table_b_gap(tmp_path: Path) -> None:
    blind = [card("said", "0.7", label="nap", card="blind", agrees="1")] * 2
    blind += [card("said", "0.7", label="nap", card="blind", agrees="0")] * 3
    blind += [card("said", "0.7", label="nap", card="blind", agrees="")]
    shown = [card("yes", "0.7", label="nap", card="normal")] * 4 + [card("no", "0.7", label="nap")]
    _, text = run(table(tmp_path, blind + shown))
    assert "| nap | 5 | 40 | 5 | 80 | 40 |" in text
    assert "| all | 5 | 40 | 5 | 80 | 40 |" in text


def test_table_b_too_few(tmp_path: Path) -> None:
    rows = [card("said", card="blind", agrees="1"), card("yes")]
    _, text = run(table(tmp_path, rows))
    assert "| walking | 1 | 100 | 1 | 100 | too few |" in text


def test_unanswered_never_counted(tmp_path: Path) -> None:
    rows = [card("not_answered", why_not="short_and_old"), card("not_answered", why_not="short_and_old"),
            card("not_answered", why_not="expired"), card(""), card("yes")]
    _, text = run(table(tmp_path, rows))
    assert "5 estimates" in text
    assert "1 answered" in text
    assert "3 not answered (expired: 1, short_and_old: 2)" in text
    assert "1 still waiting" in text
    assert "| 0.9 and up | 1 | 1 | 0 | 100 |" in text
    assert "| walking | 1 | 1 | 0 | 0 | 0 | 0 |" in text


def test_not_sure_tables(tmp_path: Path) -> None:
    rows = [card("not_sure", label="nap", age_min="30")] * 2 + [card("yes", label="nap", age_min="30")] * 3
    rows += [card("no", label="nap", age_min="100")] * 2 + [card("said", label="nap", age_min="2000")]
    rows += [card("not_sure", label="nap", age_min="1000")] + [card("yes", label="walking")]
    _, text = run(table(tmp_path, rows))
    assert "| nap | 9 | 3 | 2 | 3 | 1 | 33 | ask sooner or drop |" in text
    assert "| walking | 1 | 1 | 0 | 0 | 0 | 0 |" in text
    assert "| under 1 h | 5 | 3 | 0 | 2 | 0 | 40 | ask sooner or drop |" in text
    assert "| 1 to 3 h | 2 | 0 | 2 | 0 | 0 | 0 |" in text
    assert "| 12 to 48 h | 2 | 0 | 0 | 1 | 1 | 50 |" in text
    assert "| not known | 1 | 1 | 0 | 0 | 0 | 0 |" in text


def test_days_filter(tmp_path: Path) -> None:
    old = card("yes", start="2026-09-01T10:00:00+03:00")
    old_started_answered_recently = card("no", start="2026-09-01T10:00:00+03:00", answered="2026-11-20T10:00:00+03:00")
    path = table(tmp_path, [old, old_started_answered_recently, card("yes")])
    assert "2 estimates" in run(path)[1]
    assert "3 estimates" in run(path, "--days", "0")[1]
    assert "1 estimate in the period" in run(path, "--days", "3")[1]


def test_missing_file(tmp_path: Path) -> None:
    code, text = run(tmp_path / "nope.tsv")
    assert code == 1
    assert "nope.tsv" in text


def test_empty_table(tmp_path: Path) -> None:
    code, text = run(table(tmp_path, []))
    assert code == 0
    assert "nothing to check yet" in text
    assert "|" not in text


def test_golden_file(tmp_path: Path) -> None:
    code, text = run(GOLDEN, "--days", "0")
    assert code == 0
    assert "16 estimates in the period: 14 answered, 1 not answered (short_and_old: 1), 1 still waiting." in text
    assert "| under 0.5 | 0 | 0 | 0 | - |" in text
    assert "| 0.5 to 0.7 | 1 | 0 | 1 | 0 |" in text
    assert "| 0.7 to 0.9 | 1 | 1 | 0 | 100 |" in text
    assert "| 0.9 and up | 5 | 4 | 1 | 80 |" in text
    assert "| not given | 1 | 0 | 1 | 0 |" in text
    assert "Too few answers to tell" in text
    assert "| walking | 1 | 100 | 4 | 50 | too few |" in text
    assert "| nap | 1 | 0 | 1 | 100 | too few |" in text
    assert "| asleep | 0 | - | 3 | 67 | too few |" in text
    assert "| all | 2 | 50 | 8 | 63 | too few |" in text
    # the choice card ("Meditating or resting?", eyes closed and still) is neither a blind card nor a guess shown
    assert "| eyes_closed | 0 | - | 0 | - | too few |" in text
    assert "| eyes_closed | 1 | 0 | 0 | 0 | 1 | 0 |" in text
    assert "| walking | 7 | 2 | 2 | 1 | 2 | 14 |" in text
    assert "| nap | 3 | 1 | 0 | 1 | 1 | 33 |" in text
    assert "| asleep | 3 | 2 | 1 | 0 | 0 | 0 |" in text
    assert "| under 1 h | 8 | 2 | 1 | 1 | 4 | 13 |" in text
    assert "| not known | 6 | 3 | 2 | 1 | 0 | 17 |" in text
