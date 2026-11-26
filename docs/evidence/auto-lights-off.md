# Lights off, guessed by the app

## What it does

In the phone app (checked on made-up nights, not yet on a night of yours). For every night the app works out by
itself when you put the phone down to sleep, and writes it next to your own Lights off tap. It is shown as one muted
line in the report's "Falling asleep" part and used for nothing until it has proved itself against your taps.

## Evidence for this headband: weak

The idea is sound (the screen goes off, the eyes stay closed and still), but nothing has checked it on this headband
or on you yet: it is a rule waiting for nights to be compared with.

## What the research says

- When you go to sleep can be read from phone use alone: gaps in touchscreen use matched a movement wristband closely
  for when sleep began and ended (R² about 0.9, where 1 is a perfect match). That places the evening; it does not
  time falling asleep.
- Closed eyes are easy to see at the back of the head: this headband's back electrodes matched lab electrodes
  closely (correlation 0.90, 19 adults), though about 1 person in 10 shows little rise in alpha when closing the eyes.
- The app's falling-asleep detector, counted from your Lights off tap, was within half a minute of the sleep model on
  both real nights so far; its own rule is that it counts only after agreeing on 4 of 5 nights.

## Where the data does not support it

- No study times "lights off" from a screen and a headband together; the rule here is the project's own.
- The phone's screen state is written down every 10 seconds, so the guess cannot be finer than that.
- Reading in bed with the phone face down, or a screen that stays on, will be guessed wrong.
- A blink is found by the side electrodes; without them a night gets no guess.
- 60 seconds, 5 minutes and "4 of 5 nights" are planning values.

## How the app uses this

- At scoring time, for each sleep stretch: the first run of 60 seconds with the phone's screen off, a clean signal, no
  blink and no movement. A blink, a movement or the screen coming on starts the count again; an unreadable second
  neither counts nor starts it again.
- The report keeps it beside your tap, with the difference in minutes, and shows one muted line.
- The check: of the newest 5 nights that have both your tap and the app's guess, 4 within 5 minutes. Until then, and
  for now also after, it is used for nothing: the time to fall asleep is always counted from your tap.
- The live falling-asleep detector during the night still waits for your tap.

## Sources

- [Phone use and sleep timing (Borger 2019)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6662846/)
- [Dry headband against gel electrodes, same layout (Mikhaylov 2024)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)

## Libraries and models

- None new: the app's own detectors (this repository, MIT).

Checked: 2026-11-26
