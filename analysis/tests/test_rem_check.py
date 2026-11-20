"""rem_check.py: the dream sleep check (DECISIONS 740-749). Synthetic signals and made-up nights only: the owner's
EEG never goes into the repository. Expected values are worked out by hand from the rules, not copied from a run."""
from __future__ import annotations

import base64
import struct

import numpy as np
import pytest

import recording
import rem_check as rc

FS = 250
W, N1, N2, N3, R, GAP = "W", "N1", "N2", "N3", "R", "gap"


# ---- the probabilities ------------------------------------------------------------------------------------------------

def test_probs_round_trip_in_permille_halves_up():
    probs = [[0.1, 0.2, 0.3, 0.3, 0.1], [0.0004, 0.0005, 0.9991, 0.0, 0.0], [1.0, 0.0, 0.0, 0.0, 0.0]]
    enc = rc.encode_probs(probs)
    assert enc["order"] == "W N1 N2 N3 R" and enc["per"] == 1000
    raw = base64.b64decode(enc["data"])
    assert len(raw) == 3 * 5 * 2  # two bytes a value: 15 KB for a 10-hour night
    assert struct.unpack("<15H", raw) == (100, 200, 300, 300, 100, 0, 1, 999, 0, 0, 1000, 0, 0, 0, 0)
    assert rc.decode_probs(enc) == [[100, 200, 300, 300, 100], [0, 1, 999, 0, 0], [1000, 0, 0, 0, 0]]


@pytest.mark.parametrize("bad", [None, {}, {"order": "W N1 N2 N3 R", "per": 100, "data": ""},
                                 {"order": "W N1 N2 N3 R", "per": 1000, "data": "not base64!"},
                                 {"order": "W N1 N2 N3 R", "per": 1000, "data": base64.b64encode(b"\x00" * 8).decode()},
                                 {"order": "W N1 N2 N3 R", "per": 1000,
                                  "data": base64.b64encode(struct.pack("<5H", 1001, 0, 0, 0, 0)).decode()}])
def test_probs_that_are_not_probs_read_as_none(bad):
    assert rc.decode_probs(bad) is None


def test_probs_need_five_per_epoch():
    with pytest.raises(ValueError):
        rc.encode_probs([[0.5, 0.5]])


# ---- the eye pair -----------------------------------------------------------------------------------------------------

def _header(*channels: recording.Channel) -> recording.Header:
    return recording.Header(tuple(channels), 250, recording.PACKET_NUMBER)


def test_the_brainbit_pair_is_t3_t4():
    p = rc.eye_pair(recording.brainbit())
    assert (p.left, p.right, p.label) == (2, 3, "T3-T4")


def test_a_helmet_takes_the_pair_nearest_the_eyes_whatever_the_order():
    names = ("O1", "T8", "F8", "Cz", "T7", "F7", "O2", "Fz")
    p = rc.eye_pair(recording.diy_board(names, 250))
    assert (p.left, p.right, p.label) == (5, 2, "F7-F8")
    p = rc.eye_pair(recording.diy_board(("O1", "T8", "Cz", "T7"), 250))  # T7 and T8 are T3 and T4
    assert (p.left, p.right, p.label) == (3, 1, "T7-T8")


def test_no_pair_on_a_layout_without_one():
    assert rc.eye_pair(recording.diy_board(("O1", "O2", "Fz", "Fp1"), 250)) is None  # the breadboard's plan
    assert rc.eye_pair(recording.diy_board(("F7", "O1", "O2", "T7"), 250)) is None  # left sides only
    assert rc.eye_pair(recording.diy_board(("Ch1", "Ch2", "Ch3", "Ch4"), 250)) is None  # names, no places


def test_electrodes_placed_by_hand_at_the_eye_corners():
    loc, roc = (-0.62, 0.74, -0.26), (0.63, 0.73, -0.27)  # unit length to 0.01, as a positions file gives them
    p = rc.eye_pair(_header(recording.Channel("O1", "O1"), recording.Channel("LOC", None, loc),
                            recording.Channel("ROC", None, roc)))
    assert (p.left, p.right, p.label) == (1, 2, "LOC-ROC")
    far = (0.0, -0.36, 0.93)  # behind the crown: not near the eyes
    assert rc.eye_pair(_header(recording.Channel("A", None, (-far[1], far[1], far[2])),
                               recording.Channel("B", None, (far[1], far[1], far[2])))) is None
    not_mirrored = (0.25, 0.92, -0.30)
    assert rc.eye_pair(_header(recording.Channel("LOC", None, loc), recording.Channel("X", None, not_mirrored))) is None


# ---- the detector -----------------------------------------------------------------------------------------------------

def _noise(n: int, seed: int, uv: float = 3.0) -> np.ndarray:
    return np.random.default_rng(seed).normal(0, uv, n)


def _saccades(n: int, seconds: list[int], size: float = 50.0) -> np.ndarray:
    """A side-to-side glance in each listed second: a 0.1 s step of `size` µV and back 0.5 s later. Through the
    0.5-5 Hz filters a 50 µV glance swings about 80 µV in its second and about 33 µV in the next (the high-pass
    settling), so it counts once."""
    x = np.zeros(n)
    ramp = np.linspace(0, size, 25)
    for s in seconds:
        a = s * FS + 50
        x[a:a + 25] += ramp
        x[a + 25:a + 125] += size
        x[a + 125:a + 150] += ramp[::-1]
    return x


def test_quiet_signal_has_no_eye_movements():
    n = 4 * 30 * FS
    assert rc.eye_epochs(_noise(n, 1), _noise(n, 2)) == [0, 0, 0, 0]


def test_glances_count_once_a_second_when_left_and_right_move_apart():
    n = 3 * 30 * FS
    glances = [32, 35, 40, 41, 50, 77]  # five in epoch 1 (seconds 30-59), one in epoch 2
    g = _saccades(n, glances)
    left, right = 20_000 + _noise(n, 1, 2) + g / 2, -5_000 + _noise(n, 2, 2) - g / 2  # offsets: the electrodes' own
    assert rc.eye_epochs(left, right) == [0, 5, 1]
    swing, r, _ = rc.eye_seconds(left, right)
    assert all(swing[s] > rc.EYE_SWING_UV and r[s] < rc.EYE_MAX_R for s in glances)


def test_the_same_movement_on_both_sides_or_one_side_is_not_an_eye_movement():
    n = 2 * 30 * FS
    g = _saccades(n, list(range(3, 27, 3)), size=100)
    assert rc.eye_epochs(g + _noise(n, 1), g + _noise(n, 2)) == [0, 0]  # together: a blink or the whole head
    # one side only, the other seeing a little of it (or nothing): not the eyes. With only about 10 independent
    # values a second after the 5 Hz low-pass, unrelated noise on the other side passes r < -0.3 by chance in about
    # 1 second in 6, so a one-sided burst can still count now and then (DECISIONS 742)
    assert rc.eye_epochs(g + _noise(n, 1), g / 5 + _noise(n, 2)) == [0, 0]
    assert rc.eye_epochs(g + _noise(n, 1), np.zeros(n)) == [0, 0]  # a flat side: no correlation at all
    small = _saccades(n, list(range(3, 27, 3)), size=20)  # swings about 32 µV through the filters: under 40
    assert rc.eye_epochs(small / 2 + _noise(n, 1, 1), -small / 2 + _noise(n, 2, 1)) == [0, 0]
    g50 = _saccades(n, list(range(3, 27, 3)))
    assert rc.eye_epochs(g50 / 2 + _noise(n, 1, 1), -g50 / 2 + _noise(n, 2, 1)) == [8, 0]  # 50 µV glances, apart
    # a big glance (100 µV) settles over the next second too, so it counts twice: the rule counts seconds, not glances
    assert rc.eye_epochs(g / 2 + _noise(n, 1, 1), -g / 2 + _noise(n, 2, 1)) == [16, 0]


def test_missing_seconds_and_gross_artefacts():
    n = 4 * 30 * FS
    g = _saccades(n, [5, 6, 35, 36, 65, 66, 95])
    left, right = _noise(n, 1) + g / 2, _noise(n, 2) - g / 2
    miss = np.zeros(n, bool)
    miss[5 * FS + 10:5 * FS + 20] = True  # a hole in second 5: that second is not counted
    miss[(30 + 10) * FS:(30 + 13) * FS] = True  # three whole seconds: 27 left, still measured
    miss[(60 + 10) * FS:(60 + 14) * FS] = True  # four: under 27 left, not measured
    left[100 * FS] += 3_000  # a jump on one electrode in the last epoch: not measured
    assert rc.eye_epochs(left, right, miss) == [1, 2, None, None]
    assert rc.eye_text([1, 2, None, None, 10, 30]) == "12--au"
    assert rc.eye_from_text("12--au") == [1, 2, None, None, 10, 30]
    assert rc.eye_from_text("12x") is None


def test_a_partial_last_epoch_is_left_out():
    n = 30 * FS + 29 * FS + 100
    assert rc.eye_epochs(_noise(n, 1), _noise(n, 2)) == [0]
    assert rc.eye_epochs([], []) == []


# ---- the night's numbers ----------------------------------------------------------------------------------------------

def _night() -> tuple[list[str], list[tuple[int, int]]]:
    """10 min awake, then 120 epochs (60 min) of sleep: N2 x60, R x10, N2 x20, N3 x10, R x20; 10 min awake; a stray
    REM epoch long after (outside every period)."""
    st = [W] * 20 + [N2] * 60 + [R] * 10 + [N2] * 20 + [N3] * 10 + [R] * 20 + [W] * 20 + [W] * 150 + [R] * 2
    return st, [(20, 139)]


def test_rem_share_first_rem_and_thirds():
    st, per = _night()
    c = rc.night_check(st, per)
    assert c["asleep_min"] == 60.0 and c["rem_min"] == 15.0 and c["rem_share"] == 0.25  # the stray REM is out
    assert c["first_rem_min"] == 30.0  # epoch 80 - epoch 20
    assert c["thirds_rem_min"] == [0.0, 5.0, 10.0]  # epochs 20-59, 60-99, 100-139
    assert c["rem_prob_min"] is None and c["eye"] is None and c["validated"] is False


def test_rem_likelihood_counts_inside_the_periods_but_not_gaps():
    st, per = _night()
    st[30] = GAP
    probs = [[0, 0, 0, 0, 0] for _ in st]
    for e in range(len(st)):
        probs[e][4] = 999 if st[e] == R else 101
    probs[30][4] = 1000  # a gap epoch: left out
    c = rc.night_check(st, per, probs)
    want = (30 * 999 + (120 - 30 - 1) * 101) / 1000 / 2  # REM and the other epochs of the period
    assert c["rem_prob_min"] == round(want, 1) == 19.5


def test_eye_movement_shares():
    st, per = _night()
    ep: list[int | None] = [0] * len(st)
    for e in range(80, 90):
        ep[e] = 10  # first REM block: 10 s each
    for e in range(120, 140):
        ep[e] = 5  # second REM block
    for e in range(60, 80):
        ep[e] = 6  # light sleep just before REM
    ep[100] = None  # not measured
    ep[25] = 1
    c = rc.night_check(st, per, None, rc.eye_measured("T3-T4", ep))
    e = c["eye"]
    rem_s, other_s = 10 * 10 + 20 * 5, 20 * 6 + 1
    assert e["pair"] == "T3-T4" and e["measured_min"] == 59.5
    assert e["in_rem_share"] == round(rem_s / (rem_s + other_s), 3) == 0.623
    assert e["rem_epoch_share"] == round(30 / 119, 3)
    assert e["rem_per_min"] == round(rem_s / 15, 1) == 13.3
    assert e["other_per_min"] == round(other_s / 44.5, 1) == 2.7
    assert e["dense_share"] == {"N2": round(20 / 79, 3), "N3": 0.0, "R": 1.0}
    assert e["epochs"][:30] == "0" * 25 + "1" + "0" * 4 and e["epochs"][100] == "-" and e["epochs"][80] == "a"


def test_eye_not_measured_says_why():
    st, per = _night()
    assert rc.night_check(st, per, None, rc.eye_not(rc.NO_PAIR))["eye"] == {"pair": None, "why": rc.NO_PAIR}


def test_no_sleep():
    c = rc.night_check([W] * 40, [])
    assert (c["asleep_min"], c["rem_share"], c["first_rem_min"], c["thirds_rem_min"]) == (0.0, None, None, None)
    assert rc.check_lines(c) == ["No sleep was scored, so there is no dream sleep to check."]


def test_the_check_of_an_older_report_from_its_stages():
    st, per = _night()
    rep = {"scored": True, "data_start": "2026-11-20T03:00:00+03:00", "stages": "".join(
        {"W": "W", "N2": "2", "N3": "3", "R": "R"}[s] for s in st),
        "periods": [{"start": "2026-11-20T03:10:00+03:00", "end": "2026-11-20T04:10:00+03:00"}]}
    assert rc.periods_of(rep) == per
    assert rc.check_of_report(rep) == rc.night_check(st, per)
    assert rc.check_of_report({"scored": True}) is None  # an older laptop report has no stages
    own = rc.night_check(st, per, None, rc.eye_not("x"))
    assert rc.check_of_report(dict(rep, rem_check=own)) is own


# ---- the words --------------------------------------------------------------------------------------------------------

def test_the_words_for_a_night_with_little_dream_sleep():
    st = [W] * 10 + [N2] * 297 + [R] * 86 + [N2] * 300 + [R] * 20 + [N3] * 130
    c = rc.night_check(st, [(10, len(st) - 1)], [[0, 0, 0, 0, 120]] * len(st),
                       rc.eye_measured("T3-T4", [3] * len(st)))
    lines = rc.check_lines(c)
    assert lines[0] == "Dream sleep 53 min (13 %). Usual for adults is 20-25 %; this headband's scorer may under-count it."
    assert lines[1] == ("First dream sleep 2 h 29 min after falling asleep (usual: 1-2 h). Last third of the night "
                        "10 min, first third 0 min; usually the last third has the most.")
    assert lines[2] == ("The scorer's own dream-sleep likelihood adds up to 50 min, about the 53 min it scored: it was "
                        "seldom unsure, so a different cut-off would add little.")
    assert lines[3] == ("Side-to-side eye movements (T3-T4): 13 % of them fell in dream sleep, which is 13 % of the "
                        "measured sleep; 6.0 seconds a minute with them in dream sleep, 6.0 in other sleep.")
    assert lines[4].startswith("Dream sleep usually holds the most of them")


def test_the_words_for_other_nights():
    st = [N2] * 70 + [R] * 30
    c = rc.night_check(st, [(0, 99)], [[0, 0, 0, 0, 900]] * 100, rc.eye_not(rc.NO_PAIR))
    lines = rc.check_lines(c)
    assert lines[0].startswith("Dream sleep 15 min (30 %).") and lines[0].endswith("this night is above it.")
    assert lines[2].startswith("The scorer's own dream-sleep likelihood adds up to 45 min, more than the 15 min")
    assert lines[3] == "Eye movements: not available on this layout (no left-right pair of electrodes near the eyes)."
    c = rc.night_check([N2] * 78 + [R] * 22, [(0, 99)], [[0, 0, 0, 0, 0]] * 100)
    assert rc.check_lines(c)[0].endswith("(22 %). Usual for adults is 20-25 %; this night is within it.")
    assert rc.check_lines(c)[2].endswith("less than the 11 min it scored.")
    assert rc.check_lines(c)[3].startswith("This report is older than the check")
    c = rc.night_check([N2] * 100, [(0, 99)], None, rc.eye_measured("T3-T4", [2] * 100))
    assert rc.check_lines(c)[1] == "No dream sleep was scored inside the sleep periods."
    assert rc.check_lines(c)[2] == ("Side-to-side eye movements (T3-T4): 4.0 seconds a minute with them in sleep; "
                                    "none of the measured sleep was scored as dream sleep.")
    c = rc.night_check([N2] * 100, [(0, 99)], None, rc.eye_measured("T3-T4", [None] * 100))
    assert rc.check_lines(c)[2] == "Side-to-side eye movements (T3-T4): no clean stretch of sleep to measure."


def test_durations_round_halves_up():
    assert [rc.duration(m) for m in (0.4, 0.5, 12.5, 59.5, 60, 149.5)] == [
        "0 min", "1 min", "13 min", "1 h 00 min", "1 h 00 min", "2 h 30 min"]
