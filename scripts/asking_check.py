"""A monthly self-check of the phone's questions: are the answers honest, and are some questions worth asking?

usage: python3 scripts/asking_check.py [ESTIMATES.tsv] [--days N] [--now ISO]
       ESTIMATES.tsv  the estimates table (default: <repo>/_local/data/estimates.tsv)
       --days N       keep the estimates answered (or started, when not answered) in the last N days (default 30;
                      0 = everything)
       --now ISO      the clock to count the days from (default: now); for tests

It prints three small Markdown tables, each with one plain sentence on how to read it:
  A. the Yes rate against how sure the detector was (a Yes rate that does not fall as the detector gets less sure
     may mean the answers follow the guess);
  B. blind cards (the guess hidden) against cards that show the guess;
  C. how often the owner taps "Not sure", by kind of question and by age of the stretch.
A card nobody answered, and one still waiting, are never counted as a Yes or a No. Standard library only.
"""
from __future__ import annotations

import sys
from collections import Counter
from collections.abc import Callable, Iterable
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TABLE = ROOT / "_local" / "data" / "estimates.tsv"

# Every threshold below: planning value from research, not measured on the owner.
MIN_CARDS = 5  # fewer cards than this in a band or a row is too few to say anything
WATCH_POINTS = 10  # the lowest band's Yes rate must be lower than the highest band's by at least this many points
NOT_SURE_LIMIT = 30  # a Not sure rate (percent) over this, with MIN_CARDS answered, marks "ask sooner or drop"
DEFAULT_DAYS = 30  # the period of the check

ASKED = "ask sooner or drop"
ANSWERS = ("yes", "no", "not_sure", "said")
CONFIDENCE_BANDS = ((0.0, "under 0.5"), (0.5, "0.5 to 0.7"), (0.7, "0.7 to 0.9"), (0.9, "0.9 and up"))
NOT_GIVEN = "not given"
AGE_BANDS = ((0, "under 1 h"), (60, "1 to 3 h"), (180, "3 to 12 h"), (720, "12 to 48 h"))  # minutes
AGE_LAST = (2880, "over 48 h")
NOT_KNOWN = "not known"

Row = dict[str, str]


def number(text: str) -> float | None:
    try:
        return float(text)
    except ValueError:
        return None


def percent(part: int, whole: int) -> float | None:
    return None if whole == 0 else 100.0 * part / whole


def shown(value: float | None) -> str:
    """A rate as a whole number, halves rounded up; `-` when there was nothing to divide."""
    return "-" if value is None else str(int(value + 0.5))


def plural(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


def when(text: str, assume: timezone = timezone.utc) -> datetime | None:
    try:
        t = datetime.fromisoformat(text)
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=assume)


def read_rows(path: Path) -> list[Row]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines:
        return []
    header = lines[0].split("\t")
    rows = []
    for line in lines[1:]:
        if line.strip():
            cells = line.split("\t")
            rows.append({h: (cells[i] if i < len(cells) else "") for i, h in enumerate(header)})
    return rows


def in_period(row: Row, since: datetime | None, now: datetime) -> bool:
    if since is None:
        return True
    t = when(row.get("answered", "") or row.get("start", ""))
    return t is None or since <= t <= now


def markdown(head: list[str], body: list[list[str]]) -> list[str]:
    rule = ["---"] * len(head)
    return ["| " + " | ".join(cells) + " |" for cells in [head, rule, *body]]


def confidence_band(row: Row) -> str:
    c = number(row.get("confidence", ""))
    if c is None:
        return NOT_GIVEN
    name = CONFIDENCE_BANDS[0][1]
    for low, label in CONFIDENCE_BANDS:
        if c >= low:
            name = label
    return name


def age_band(row: Row) -> str:
    a = number(row.get("age_min", ""))
    if a is None:
        return NOT_KNOWN
    name = AGE_BANDS[0][1]
    for low, label in AGE_BANDS:
        if a >= low:
            name = label
    return AGE_LAST[1] if a >= AGE_LAST[0] else name


def is_guess_shown(row: Row) -> bool:
    return row.get("card", "") != "blind" and row.get("answer", "") in ("yes", "no")


def summary(rows: list[Row]) -> str:
    answers = Counter(r.get("answer", "") for r in rows)
    answered = sum(answers[a] for a in ANSWERS)
    why = Counter(r.get("why_not", "") or "unknown" for r in rows if r.get("answer", "") == "not_answered")
    parts = [f"{answered} answered"]
    if answers["not_answered"]:
        reasons = ", ".join(f"{k}: {v}" for k, v in sorted(why.items()))
        parts.append(f"{answers['not_answered']} not answered ({reasons})")
    else:
        parts.append("0 not answered")
    waiting = sum(1 for r in rows if r.get("answer", "") not in (*ANSWERS, "not_answered"))
    parts.append(f"{waiting} still waiting")
    return f"{plural(len(rows), 'estimate')} in the period: " + ", ".join(parts) + "."


def table_a(rows: list[Row]) -> list[str]:
    cards = [r for r in rows if is_guess_shown(r)]
    names = [label for _, label in CONFIDENCE_BANDS] + [NOT_GIVEN]
    counts = {n: Counter(r["answer"] for r in cards if confidence_band(r) == n) for n in names}
    body = []
    for n in names:
        yes, no = counts[n]["yes"], counts[n]["no"]
        body.append([n, str(yes + no), str(yes), str(no), shown(percent(yes, yes + no))])
    out = ["A. Yes rate against how sure the detector was", ""]
    out += markdown(["How sure the detector was", "Cards", "Yes", "No", "Yes rate %"], body)
    out += ["", "How to read it: the Yes rate should fall as the detector gets less sure; if it stays high everywhere, "
            "the answers may be following the guess.", ""]
    filled = [n for n in names[:-1] if sum(counts[n][a] for a in ("yes", "no")) > 0]
    out.append(watch_line(counts, filled))
    return out


def watch_line(counts: dict[str, Counter[str]], filled: list[str]) -> str:
    if not filled:
        return "Too few answers to tell."
    low, high = counts[filled[0]], counts[filled[-1]]
    n_low, n_high = low["yes"] + low["no"], high["yes"] + high["no"]
    if filled[0] == filled[-1] or n_low < MIN_CARDS or n_high < MIN_CARDS:
        return f"Too few answers to tell (need {MIN_CARDS} Yes or No cards in the lowest and the highest band)."
    r_low, r_high = 100.0 * low["yes"] / n_low, 100.0 * high["yes"] / n_high
    if r_high - r_low < WATCH_POINTS:
        return (f"Watch: the Yes rate is {shown(r_low)} % when the detector is least sure and {shown(r_high)} % when "
                "it is most sure; answers may be following the guess.")
    return "Looks fine: the Yes rate falls as the detector gets less sure."


def table_b(rows: list[Row]) -> list[str]:
    labels = sorted({r.get("label", "") for r in rows if r.get("label", "")})
    body = [b_row(name, [r for r in rows if r.get("label", "") == name]) for name in labels]
    body.append(b_row("all", rows))
    out = ["B. Blind cards against cards that show the guess", ""]
    head = ["What the detector guessed", "Blind cards", "Agreed %", "Guess cards", "Yes rate %", "Gap points"]
    out += markdown(head, body)
    out += ["", "How to read it: the gap is how far showing the guess pulls the answers toward Yes."]
    return out


def b_row(name: str, rows: list[Row]) -> list[str]:
    blind = [r for r in rows if r.get("card", "") == "blind" and r.get("answer", "") == "said"
             and r.get("agrees", "") in ("0", "1")]
    agree = sum(1 for r in blind if r["agrees"] == "1")
    cards = [r for r in rows if is_guess_shown(r)]
    yes = sum(1 for r in cards if r["answer"] == "yes")
    p_agree, p_yes = percent(agree, len(blind)), percent(yes, len(cards))
    gap = "too few"
    if p_agree is not None and p_yes is not None and len(blind) >= MIN_CARDS and len(cards) >= MIN_CARDS:
        gap = shown(p_yes - p_agree)
    return [name, str(len(blind)), shown(p_agree), str(len(cards)), shown(p_yes), gap]


def table_c(rows: list[Row], key: Callable[[Row], str], names: Iterable[str], title: str) -> list[str]:
    body = []
    for n in names:
        counts = Counter(r["answer"] for r in rows if r.get("answer", "") in ANSWERS and key(r) == n)
        total = sum(counts.values())
        if total == 0:
            continue
        rate = percent(counts["not_sure"], total)
        mark = ASKED if rate is not None and rate > NOT_SURE_LIMIT and total >= MIN_CARDS else ""
        body.append([n, str(total), str(counts["yes"]), str(counts["no"]), str(counts["not_sure"]),
                     str(counts["said"]), shown(rate), mark])
    head = [title, "Answered", "Yes", "No", "Not sure", "Said (blind card)", "Not sure %", "Note"]
    return markdown(head, body)


def not_sure_section(rows: list[Row]) -> list[str]:
    labels = sorted({r.get("label", "") for r in rows if r.get("label", "")})
    ages = [label for _, label in AGE_BANDS] + [AGE_LAST[1], NOT_KNOWN]
    out = ["C. Not sure", ""]
    out += table_c(rows, lambda r: r.get("label", ""), labels, "Kind of question")
    out += [""] + table_c(rows, age_band, ages, "Age of the stretch when asked")
    out += ["", f"How to read it: a high Not sure rate (over {NOT_SURE_LIMIT} % with at least {MIN_CARDS} answered) "
            "means you often cannot tell; ask sooner after the stretch, or stop asking."]
    return out


def parse_args(argv: list[str]) -> tuple[Path, int, datetime] | str:
    path, days, now = DEFAULT_TABLE, DEFAULT_DAYS, datetime.now(timezone.utc)
    args = list(argv)
    while args:
        a = args.pop(0)
        if a in ("--days", "--now") and args:
            v = args.pop(0)
            if a == "--days" and v.isdigit():
                days = int(v)
            elif a == "--now" and when(v) is not None:
                now = when(v) or now
            else:
                return f"I could not read {a} {v}."
        elif a.startswith("-"):
            return f"I do not know the option {a}."
        else:
            path = Path(a)
    return path, days, now


def main(argv: list[str], out: Callable[[str], object] = print) -> int:
    parsed = parse_args(argv)
    if isinstance(parsed, str):
        out(parsed)
        return 2
    path, days, now = parsed
    if not path.is_file():
        out(f"There is no estimates table at {path}.")
        return 1
    since = now - timedelta(days=days) if days > 0 else None
    rows = [r for r in read_rows(path) if in_period(r, since, now)]
    if not rows:
        out("There are no estimates in the period: nothing to check yet.")
        return 0
    sections = [[summary(rows)], table_a(rows), table_b(rows), not_sure_section(rows)]
    out("\n\n".join("\n".join(s) for s in sections))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
