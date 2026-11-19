---
name: EEG Tracker
description: Night recorder for an EEG headband; a ship's bridge on the night watch, readable half-asleep
colors:
  ground: "#100D0B"
  surface: "#18140F"
  surface-high: "#211B15"
  ink: "#DCCDB6"
  ink-muted: "#A99A84"
  rule: "#3A322A"
  track: "#26201A"
  saved: "#8C7F6C"
  live: "#7FC49A"
  live-fill: "#2E6B4B"
  on-live-fill: "#E8F3EC"
  caution: "#E0AE5C"
  problem: "#E57A63"
typography:
  status:
    fontFamily: "Roboto"
    fontSize: "36sp"
    fontWeight: 500
  readout:
    fontFamily: "Roboto (tabular figures)"
    fontSize: "45sp"
    fontWeight: 400
    lineHeight: 1
  heading:
    fontFamily: "Roboto"
    fontSize: "16sp"
    fontWeight: 500
  body:
    fontFamily: "Roboto"
    fontSize: "16sp"
    fontWeight: 400
rounded:
  cell: "6px"
  button: "16px"
spacing:
  page: "24px"
  section: "32px"
  cell-gap: "6px"
components:
  button-start:
    backgroundColor: "{colors.live-fill}"
    textColor: "{colors.on-live-fill}"
    rounded: "{rounded.button}"
    height: "64px"
  button-stop:
    textColor: "{colors.ink}"
    rounded: "{rounded.button}"
    height: "64px"
  strip-cell:
    backgroundColor: "{colors.track}"
    rounded: "{rounded.cell}"
    size: "32px"
---

# Design System: EEG Tracker

## Overview

The recorder is used in a dark bedroom, by someone tired, at arm's length. The world is a ship's bridge on
the night watch: everything dim and warm so dark-adapted eyes are not dazzled, states told by the
navigation-light trio, and the night kept like a deck log, half hour by half hour. Material 3 governs
structure and controls; the world lends only palette, type, density and one signature: the watch strip.
Dark is not a style choice here; it comes from the scene. Source: `app/lib/ui/theme.dart`.

## Colors

- **Ground and ink:** warm chart-table black (`ground`) with parchment `ink` (12:1) and `ink-muted` (7:1)
  for labels. No pure white anywhere; no large bright fields.
- **Navigation-light trio, dimmed:** `live` green = recording, good contact, the live half hour and the
  Start button (as the deep `live-fill`); `caution` amber = gaps, fair contact, phone problems;
  `problem` red = no data, poor contact, empty half hours. A colour always repeats a word or a shape;
  nothing is told by colour alone.
- **Strip:** `track` for an empty cell, `saved` for a fully saved half hour (visible, never bright).

## Typography

Roboto only, on the Material type scale (sp, follows the system font size). Status word at display size;
readout numbers at displayMedium with tabular figures, units one step smaller beside them; section
headings titleMedium 500; everything else bodyLarge. No monospace, no display face.

## Layout

One scrolling column, 24 dp page margins, sections separated by a hairline and 32 dp above the heading.
Order: status, readouts, watch strip, then Headband and Phone (Phone first before a night, Headband first
during one). Between nights the Sleep section (last night's asleep total and a Sleep report button) comes
right after the strip, then the Morning section (today's check-in, Morning check-in and Trends buttons). The
primary action is pinned at the bottom, full width, 64 dp; while a night records the pinned bar is a hairline, one
muted line about the drift-off detector, then Lights off and Stop side by side (3 : 2). The sleep report is its own page: totals, the honest
note, the chart, the periods, jaw and movement with
the night hour by hour, past nights. The morning check-in is one page per step with the steps as state marks
at the top; trends is a day log (today's entry, sleep pressure, the last 14 days, earlier days, the forecast).
Between nights a "Your data" section (after Headband) says what the app keeps and when it last left the phone, with
Export data and Export a night. Export data is its own page: status word, what is new as two readouts, the copy
strip, the route (this phone, the folder, the laptop) as numbered log rows, Export everything, and Export new pinned.
Settings (a gear in the night screen's app bar) holds the hands-free switch, its calibration with Calibrate right under
it, what each gesture does where (two label-over-value columns per session), and how often it is wrong; the
hands-free calibration is a page of its own with the six tries on top, the instruction at display size, the two live
lanes and the one action pinned (Start, Stop, then Done or Try again).
Self-experiments (from Trends) is a page per experiment: status, today's task, "did you keep to it?", the day bill,
the answer's place, Kept honest; its setup is a page of choices with Start tomorrow pinned.
Sharp hours (from Trends; the assistant's proposal) is one page: a muted sentence saying whose idea it is, the switch
row, Awake and A day as label-left / value-right rows, the delivery line, Collecting with the collection ledger, By the
hour (chips, then the ratings' and the reaction times' charts), Today, Your data; Rate now pinned. Its question page
shows one decision at a time: the question at headlineSmall and five full-width 64 dp rows (5 Very sharp at the top);
then the reaction test, with Skip outlined until a test is done and Done filled after.

## Elevation & Depth

One ply. No cards, no shadows, no glow; hairline rules group content. Dialogs and snackbars use
`surface-high`.

## Shapes

Cells 6 dp radius, buttons 16 dp. State marks are circles: filled (good / live), ringed dot (fair), ring
(poor or idle), dash (no reading).

## Components

- **Watch strip:** one row per four clock hours, eight half-hour cells, a wider gap every two hours.
  A cell fills from the bottom with the share of samples saved; a gap shows amber, an empty half hour a
  red outline, the half hour in progress a green outline. Clock slots outside the night stay as faint
  outlines so columns never move.
- **Readouts:** big numbers with small units and a muted label under them; data age turns amber at 5 s
  and red at 40 s.
- **Sleep chart (sleep report):** the night's stages on the clock: an ink step line through four worded
  levels (Awake, Dream, Light, Deep) on the `track` ground, hour rules, missing data hatched in `caution`
  amber like the strip's gaps, each sleep period a faint `rule` band numbered above the chart and in the
  period log below it. No stage colours: the levels are words. When the report has the detectors' extras, a
  Signal lane runs under the levels on the same clock, worded "Signal" like them: the empty `track` where the
  signal was clean, `caution` amber dots where the model read through noise, solid amber where no electrode was
  usable; both in the legend.
- **Sleep periods:** ruled log entries: a numbered cell, the clock span, then label-left / minutes-right
  lines (Asleep, Deep, Dream, Light), wake-ups and missing minutes as plain sentences.
- **Day entries (trends, check-in result):** label left, value right in tabular titleLarge, then yesterday's value
  and your usual in muted body, then the arrow's meaning in words with the normal range. An arrow is a drawn
  north / south icon in ink beside the value, never a colour; no arrow before 14 days of values.
- **Watch bill (trends):** one row per measure, fourteen of the strip's own cells (track, 6 dp), oldest left, today
  outlined in ink-muted; the normal range a faint rule band; the values an ink line, a dot where a day stands
  alone; a day without a value stays an empty cell. Weekday letters under the last row.
- **Sleep-pressure chart:** 36 hours on the track ground, sleep periods as rule bands, dashed worded levels
  ("rested", "regular bedtime"), an ink line that stops where the log cannot tell, now as a hairline with a dot.
- **Night extras (sleep report):** the honest note adds one sentence on how much of the sleep was read through
  noise. "Jaw and movement" (a heading with an "i") uses the period lines' label-left / value-right form for the
  two rates an hour asleep, then plain sentences: the counts, the earlier nights' jaw rates, and "a trend to
  compare your nights, not a test for teeth grinding". "Hour by hour" is a table of log rows: the hour in
  tabular figures, the Signal lane's marks as a bar whose full width is 60 recorded minutes, then Jaw and Moves
  right-aligned; the swatches and one muted sentence under it. Past nights add "jaw N an hour".
- **Lights off bar** (night screen, while a night records): a hairline sets it apart from the page scrolling under
  it; above the buttons one muted bodyMedium line in words, tabular figures ("Tap Lights off as you close your eyes
  to sleep." / "Lights off 23:42. Asleep since 23:51, by the detector."), no colour for the detector's states; Lights
  off is the night's one filled button (`live-fill`, a moon icon) until tapped, then an outlined "Lights off again"
  in the same place that asks before it moves the moment; Stop stays outlined beside it.
- **Falling asleep** (sleep report, after the periods): a heading with an "i", a muted lead line ("Lights off at
  23:45. From then until asleep:"), two label-left / value-right lines in the periods' form (The detector, The sleep
  model; half minutes as ½), then plain sentences: agree or not, where lights off came from when it was not a tap,
  the check toward 4 of 5 nights, and "Both are guesses" in muted ink. No ring, no score.
- **Alarm line** (night screen, pinned bar): the smart alarm in one muted bodyMedium line with a small sunrise icon and
  one text button at its right. Before a night it sits above Start night under a hairline ("Smart alarm off." / "Wakes
  you by 07:30 tomorrow, from 07:00 at a light moment.", **Set alarm** / **Change**); while a night records it is a
  second line under the Lights off line ("Alarm 07:00-07:30. Watching your sleep: deep sleep 2 min ago.", **Alarm off**,
  which asks). Words only for the stages, no colour. Its sheet (`surface-high`): the wake-by time as a tabular
  displayMedium figure that opens the system's 24-hour time picker, the window as the app's segmented choice row
  (selected one step lighter, `rule`), two muted sentences of the rule and the safety net, then Alarm off (outlined)
  and Set alarm (filled) side by side.
- **Wake face** (night screen while the alarm rings, and the native page over the lock screen): the nap coach's wake:
  "Time to wake up" at display size, why it rang and "the night is still recording" in muted body, and one `live-fill`
  **I'm awake** filling the rest of the screen. The only time the night screen is lit and loud on purpose.
- **Waking up** (sleep report, after Falling asleep): a heading with an "i", a muted lead ("Smart alarm 07:00-07:30."),
  label-left / value-right lines (Woke you as a tabular titleLarge time, Why, Full-night scoring, I'm awake after),
  then plain sentences: how early and that the live model read it 2 minutes behind, whether the full-night scoring
  agrees ("not deep sleep" / "the live reading was wrong this time"), and in muted ink that both are guesses.
- **DIY board (test)** (Headband connection page and night screen; DECISIONS 360-369): the device choice is the app's
  segmented row (BrainBit | DIY board (test), selected one step lighter) under a "Headband" heading, with one muted
  sentence; with the board chosen the status mark is a ringed dot in `caution` with the words "DIY board (test)", and
  the page has no pinned action. Its sections: Safety (ink body text: the app only listens; nothing makes the board
  safe for a body or power, nothing changes its gates), Where the board sends (This phone / Port as label-left /
  value-right rows in tabular titleLarge, an amber Wi-Fi-off row with its icon when there is no address, the
  firmware settings in muted body), Channels (CH1-CH4 as muted label over titleLarge name, the names field, Save
  names), With the board (what goes where and what is off, in sentences). On the night screen while it records,
  the Headband block replaces battery, signal and contact: "DIY board (test)", the mode as a `caution` ringed dot
  with "Test signal, not EEG" in titleLarge words, then "Swing over the last second, µV" over four name-over-value
  cells in the contact cells' place (tabular titleLarge, no colour), then one muted line with the link and the lost
  samples. Between nights the block is one line and the channel names, the Sleep section says in words that the
  board's nights get no report, and the Phone section drops the Bluetooth rows.
- **Phone checks:** icon, one plain sentence, right-aligned text buttons that open the exact setting.
- **Export line** (Your data): an icon and one sentence, muted ("Last export yesterday; 3 new files since"), or
  `caution` amber with a warning icon once something new has been only on the phone for 3 days, or nothing was ever
  exported. Never colour alone: the sentence says what is at risk.
- **Share row and sheet** (Your data): a Material switch row "Share on Wi-Fi" under a hairline, one muted sentence
  under it (amber with words when there is no Wi-Fi address or it stopped), and the text button Address and code. The
  sheet uses label-left / value-right rows (Address, Code, Turns off at) in tabular titleLarge with copy icons, the two
  laptop commands as selectable body text, and a QR code drawn in `ground` on an `ink` field: the one light field in
  the app, parchment instead of white, because a camera needs the contrast.
- **Copy strip** (Export data): sixteen of the watch strip's own cells (track, 6 dp, a wider gap every four), filling
  from the left with `saved` by the share of the phone's data that has reached the export folder; while copying,
  the cell in progress is outlined green like the half hour in progress. A muted sentence under it gives both sizes.
- **Day bill** (self-experiments): one row per week, seven of the watch strip's own cells under weekday letters:
  a "do" day filled `saved`, a "don't" day outlined in ink-muted on `track`, a day not kept keeps its cell and gets
  a cross, today outlined green like the half hour in progress, days ahead faint `rule` outlines (sealed). The
  legend says all of it in words. The answer has its place on the page from day 1: "Sealed until <date>", later
  one sentence in titleLarge with its range and verdict, then log rows; a look before the end is an amber warning
  line with its icon.
- **Gesture lanes** (hands-free calibration): two `track` lanes of the last 10 seconds, worded "Jaw" and "Eyes" like the
  sleep chart's levels. Jaw: a bar per 0.1 s on a log scale (1 to 100 times your rest), `saved` under the clench line
  and `ink` over it, the line dashed in ink and labelled "first guess" or "yours". Eyes: an ink step line from the
  middle (up for one side, down for the other, holding between moves) with the look size as faint `rule` lines. The
  six tries above them are the watch strip's cells under two words: a faint outline to come, a green ring while
  cued, filled `saved` when seen or caught, a `track` cell with an amber dash when not, an `ink-muted` ring while not
  yet judged.
- **Unusual for you** (trends, the slot after the summary line): a hairline heading with its "i" and a Material switch
  beside it, the same place in every state; most days one muted bodyLarge line ("Learning your usual: 12 of 28 days",
  "Nothing unusual for you lately" with its record); a card is the day's first entry, one sentence in titleLarge ink,
  further numbers in bodyLarge ink, what it is based on and the everyday causes in muted body, "If you can, take it
  easy today", then "What might explain it?" as Material filter chips (ground, rule outline; chosen: surfaceHigh, an
  ink check mark and an ink-muted outline). "Back in your usual range" and "Paused until ..." (with a Resume now text
  button) take the same place. No colour means anything here; while there is a card the Morning section on the night
  screen adds one bodyLarge ink line above its buttons.
- **Collection ledger** (sharp hours): the watch strip's own cells counting toward the first pattern: 60 answer cells
  in three rows of 20 and 21 day cells in one row, a wider gap every five, filled `saved` as answers and days come in,
  `track` while empty; a muted label left and "26 of 60" right. Gone once the pattern opens.
- **Sharp-hours chart:** one column per block (2 clock hours, 2 hours since waking, a quarter of the sleep-pressure
  scale) on the `track` ground, the two worded ends at the left (Very sharp / Foggy, or quicker / slower), block edges
  as ticks under it; answers as ink dots side by side per level, so a count reads as a row; once the pattern opens the
  dots turn ink-muted, each block with enough answers gets its range as a `rule` band and its mean as an ink tick, and
  the named best block (or two) is outlined in ink-muted. The sentence under it says the same in words.
- **Buttons:** one filled button per screen: Start night on the night screen (Lights off while a night records), Start on the meditation screen, and on
  each training page its one step forward (Check in, Save, Agree and continue); Stop is outlined and asks once before
  stopping, except in alpha-theta, where stopping must be instant. Session faces (dream catcher, sound for states)
  are true black with words only.
- **Sound score** (sound for states): the session drawn before Start, its real minutes left to right: the quiet
  minute an empty `rule` cell, the sound's loudness a `track` band that fades in and out, the beat's rate an ink
  line (log scale, its two ends worded in Hz), minute ticks; a thin green rule where a session is, and afterwards the
  played part in `saved` with an ink rule where it ended.
- **Questions** (training pages): the question in body text, then a Material segmented row (a 1-5 scale with both
  ends worded under it, or a few words like Live / Replay / Not sure), a slider that reads "not set" until moved, or a
  checklist with the box first. Nothing is preselected; the forward button says "Answer each question" until done.

## Do's and Don'ts

- Do keep every value in the same place across states; the eye finds it at 3 a.m. without reading.
- Do word every state ("Recording", "No data for 52 s") next to its colour.
- Don't add bright fills, animation beyond the slow breathing live mark, or sounds. Exceptions: the meditation
  mode, whose feedback is sound (rain, drone, bells; DECISIONS 72-77), and the practices built the same way
  (alpha-theta, the dream catcher, sound for states, whose product is sound); the night screen stays silent until
  the smart alarm you set rings (DECISIONS 235).
- Don't show a number that was not measured; label planning thresholds as such.
