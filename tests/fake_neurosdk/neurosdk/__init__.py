"""A fake BrainBit SDK (same names as pyneurosdk2) so the recorder and pages can run without a headband.

usage: PYTHONPATH=tests/fake_neurosdk python3 scripts/record_night.py --seconds 30 --port 8799 --out /tmp/rec
The fake signal (volts, 250 Hz, batches of 25 every 0.1 s): back channels O1/O2 carry 10 Hz alpha that is strong
for 60 s ("eyes closed") and weak for 60 s ("eyes open"), alternating from the start; every 45 s the side channels
T3/T4 get a 3 s burst of fast muscle noise ("jaw clench"); every 7 s O1/O2/T3/T4 show a 0.3 s blink-like bump.
Pure Python (the real recorder must never import numpy). FAKE_BRAINBIT_SEED makes the noise repeatable.
"""
