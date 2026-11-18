# Eyes open or closed

## What it does

A live test of the back electrodes: a high beep while your eyes are open, a low beep while they are closed,
worked out from the alpha rhythm (the 8-12 Hz wave at the back of the head that grows when you close your eyes).
Calibrate once: 10 s eyes open, then 10 s eyes closed.

## Evidence for this headband: strong

Alpha at the back of the head jumps when the eyes close, one of the most reliable effects in EEG, and this
headband's back electrodes match lab electrodes.

## What the research says

- A dry headband with exactly this layout matched lab gel electrodes for back-of-head alpha (correlation 0.90 in
  19 adults). The side electrodes (T3, T4) showed no eyes-closed alpha rise on either system, so only the back
  pair is used.
- About one person in ten shows little or no alpha rise on closing the eyes; this test tells you whether you are
  one of them.
- Drowsiness flips the rule: with eyes open, rising alpha can mean you are getting sleepy; with eyes closed,
  falling alpha means you are drifting off.
- The reference electrode sits on the forehead, so blinks show on all four channels and can look like a jump.

## Where the data does not support it

- It reads alpha, not your eyelids: drowsy with eyes open can look "closed", and dozing with eyes closed can look
  "open".
- It is a signal check and a demonstration, not a measure of relaxation or focus.
- With poor contact at the back electrodes, open and closed look alike.

## How the app uses this

- Four times a second: alpha power (8-12 Hz) against its neighbours (4-6 and 15-20 Hz) over the last second, at
  O1 and O2, on a log scale. Using neighbours makes it robust to how loud the whole signal is.
- Calibration takes the middle value of the eyes-open and eyes-closed seconds and puts the line half-way. If the
  two differ by less than about 1.4 times, the page says they look alike and to check contact.
- A small margin on each side of the line stops flicker. A flat or very large signal (over 400 µV: movement or a
  blink) shows "…" instead of a guess.
- The same eyes-closed alpha feeds the morning check-in, the brain sound and the alpha bar on the headband check
  page.

## Sources

- [Mikhaylov 2024: dry headband vs gel, same layout](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)
- [Alpha basics (StatPearls)](https://www.ncbi.nlm.nih.gov/books/NBK537023/)
- [Sleepiness ratings vs EEG (Kaida 2006)](https://data.zhenzhi.com/details/1/905755554)
- [BrainBit device notes (forehead reference)](https://sdk.brainbit.com/device-recommendation)

## Libraries and models

- None: plain JavaScript in the page; the beeps use the browser's built-in Web Audio.

Checked: 2026-11-18
