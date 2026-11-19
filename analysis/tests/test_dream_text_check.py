"""scripts/dream_text_check.py: the word error rate and the phone's level step (the recognizer itself needs the
downloaded models and runs by hand, README "Dream catcher")."""
import numpy as np

import dream_text_check as dt


def test_words_are_compared_without_case_punctuation_or_yo():
    assert dt.norm("Я шёл по коридору, а двери всё не кончались.") == "я шел по коридору а двери все не кончались".split()
    assert dt.norm("I'm here.") == ["i'm", "here"]


def test_word_edits_count_substitutions_insertions_and_deletions():
    ref = "a staircase going up into the clouds".split()
    assert dt.edits(ref, ref) == 0
    assert dt.edits(ref, "it was a staircase going up into the clouds".split()) == 2
    assert dt.edits(ref, "a staircase going into clouds".split()) == 2
    assert dt.edits(ref, "a staircase going up into the cloud".split()) == 1
    assert dt.edits(ref, []) == len(ref)


def test_a_quiet_answer_is_raised_to_minus_3_dbfs_at_most_30_db_never_lowered():
    assert np.abs(dt.level(np.array([0.01, -0.05], dtype=np.float32))).max() == np.float32(10 ** (-3 / 20))
    assert np.isclose(np.abs(dt.level(np.array([0.0002], dtype=np.float32))).max(), 0.0002 * 10 ** 1.5)
    assert np.abs(dt.level(np.array([0.9], dtype=np.float32))).max() == np.float32(0.9)
