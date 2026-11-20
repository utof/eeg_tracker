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
- **Storage tones:** the Storage page's bar gives each kind of data a dim warm tone of its own (sand, sage, heather,
  slate, tan, mauve, parchment, olive, umber, smoke; `app/lib/ui/storage_bar.dart`), never the trio's green, amber or
  red, and each repeats as a 12 dp swatch beside its row's name: the colour never stands alone.

## Typography

Roboto only, on the Material type scale (sp, follows the system font size). Status word at display size;
readout numbers at displayMedium with tabular figures, units one step smaller beside them; section
headings titleMedium 500; everything else bodyLarge. No monospace, no display face.

## Layout

A Material 3 navigation bar at the bottom of the main screen (DECISIONS 597-598): Night, Sessions, Signal, Trends, More,
on the ground under a hairline, the chosen tab's pill one step lighter (`rule`) with ink icon and label, the others
ink-muted, labels always shown, no animation between tabs. The app opens on Night; the night screen's sections are
split among Night, Sessions and More in their old order, and Night keeps its pinned bar above the tab bar.
One scrolling column, 24 dp page margins, sections separated by a hairline and 32 dp above the heading.
Order: status, readouts, watch strip, then Headband and Phone (Phone first before a night, Headband first
during one). Between nights the Sleep section (last night's asleep total and a Sleep report button) comes
right after the strip, then the Morning section (today's check-in, Morning check-in and Trends buttons), then Try these
(one muted line with the tally and the next stop, and a Try these button). The
primary action is pinned at the bottom, full width, 64 dp; while a night records the pinned bar is a hairline, one
muted line about the drift-off detector, then Lights off and Stop side by side (3 : 2). The sleep report is its own page: totals, the honest
note, the chart, the periods, jaw and movement with
the night hour by hour, past nights. The morning check-in is one page per step with the steps as state marks
at the top; trends is a day log (today's entry, sleep pressure, the last 14 days, earlier days, the forecast).
Between nights a "Your data" section (after Headband) says what the app keeps and when it last left the phone, with
Export data and Export a night. Export data is its own page: status word, what is new as two readouts, the copy
strip, the route (this phone, the folder, the laptop) as numbered log rows, Export everything, and Export new pinned.
Settings (a gear in the night screen's app bar) holds the hands-free switch, its calibration with Calibrate right under
it, what each gesture does where (two label-over-value columns per session), and how often it is wrong, then the
"Was this you?" section (heading row with its "i" and switch, status, whose idea, what it does, how often wrong); the
hands-free calibration is a page of its own with the six tries on top, the instruction at display size, the two live
lanes and the one action pinned (Start, Stop, then Done or Try again).
Self-experiments (from Trends) is a page per experiment: status, today's task, "did you keep to it?", the day bill,
the answer's place, Kept honest; its setup is a page of choices with Start tomorrow pinned.
Sharp hours (from Trends; the assistant's proposal) is one page: a muted sentence saying whose idea it is, the switch
row, Awake and A day as label-left / value-right rows, the delivery line, Collecting with the collection ledger, By the
hour (chips, then the ratings' and the reaction times' charts), Today, Your data; Rate now pinned. Its question page
shows one decision at a time: the question at headlineSmall and five full-width 64 dp rows (5 Very sharp at the top);
then the reaction test, with Skip outlined until a test is done and Done filled after.
Study reminders (from Settings, the first row; the assistant's proposal) is one page: a muted sentence saying whose idea it
is, the switch row ("Evening study, morning review"), Evening and Morning as label-left / value-right rows with Change and
one muted line each saying where the time comes from, the delivery line, Log it yourself (two outlined buttons), Today,
The last 14 days, Your data. Its question page shows one decision at a time: the question at headlineSmall and full-width
64 dp rows (Yes, No; Well, Some, A little) with a text button, Not yet, then the saved line and Done pinned.
Lucid dreams (a section between nights after Nap coach) is one page ordered by what is due: the status word, then the
morning's questions or Tonight (the plan lane, practice, loudness and the night's number in the test), Last night (its
lane and log rows), The test (the night cells and the sealed answer, later the tested table), How it works, Who should
not use it and the switch; the due action pinned (Start practice, Save answers, Turn on). The evening practice is its
own page: the loudness on the ground with I hear it and Stop pinned (3 : 2), then the words and the eyes-closed cues on
a true-black face with one dim counter.
Memory cues (from Settings, the row under Study reminders; the assistant's proposal; a section on the night screen
between nights once switched on) is one page: a muted sentence saying whose idea it is and how weak the evidence, the
status word, the switch row, Tonight / This morning / Night of the test / Bell and Knock loudness as label-left /
value-right rows, Last night (the drift map, then its log rows), The test (the night cells, sealed until night 12, later the tested
table), How it works, Who should not use it; the due action pinned (Turn on, Start the evening task, Start the morning
test; nothing when tonight is ready). The evening task and the morning test are pages of their own: the task cells at
the top, the object to place and one instruction line beside it, the board under them, Stop outlined and pinned; the
intro as numbered log rows with Start pinned; the loudness on the ground with I hear it and Stop pinned (3 : 2); the
morning's question as the choice column, then the result: an Evening / Morning table and the drift map, Done pinned.
Try these (from its section on the night screen) is one page in the order of a first week: the tally ("4 of 20 tried",
"1 skipped" muted at the right) over the try ledger, one muted sentence, then the stops under hairline headings by when
(Tonight, then the morning; Another night; Sessions, when you have time; Over the next weeks; When the headband is
charged). A stop is a log row: its number cell, the title, how long in muted body, "The assistant's idea." for a
proposal. One stop is open at a time (the next one at first): its sentence, whose idea (a muted line with a bulb), What
to do as numbered lines, the outlined button to its screen, Then tell the assistant as bullets, the dream catcher's
underline note field, then Done (filled, the page's one filled button) and Skip (a text button) at 3 : 2. Done or Skip
folds the stop into "Done and skipped" (behind Show N stops) and the next one opens and scrolls into view. The note has
its muted label, "What happened". With every stop done or skipped, an outlined Open Export data sits under the sentence.

Storage (More, its own section and page; DECISIONS 690-699, the owner's "like Telegram's Storage Usage") is one page:
the app's space as a readout with the phone's free space in one muted line, the storage bar (one stacked 20 dp bar of
the kinds in their tones, 2 dp gaps, 6 dp radius; a tap opens that kind below), "On the laptop, checked" as a
label-left / value-right row, then On this phone: one hairline row per kind (checkbox, swatch, name, size in tabular
figures, chevron), open to its parts indented with their own checkbox only where something may go and "Always kept"
for the statistics; one muted line on what Clear selected deletes; Automatic, the owner's promise in ink and a 4-stop
slider per kind (3 days, 1 week, 1 month, Never; the chosen word in ink); the Danger zone last, after a hairline in
`problem` red, its heading in red, its own rows and an outlined red button that asks twice. **Clear selected · size**
is pinned, filled, 64 dp.

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
- **Signal page** (the Signal tab; DECISIONS 590-599): a compact state line (the state mark, the word at titleLarge, one
  muted sentence; amber or red with words when something is wrong, its one action as a text button at the right),
  then Head / Traces / Raw as the app's segmented row (48 dp). **Head**: the 3D head fills the top half, flat-shaded in
  the ground's browns (no highlight brighter than `rule`'s neighbour), the cap's three guide lines in a faint brown;
  each electrode a DESIGN mark on a dark disc (filled `live` good, ringed `caution` dot fair, `problem` ring poor,
  `ink-muted` dash none), the reference and bias as ink-muted squares, the picked one ringed in ink; its name and ohms
  beside it on a dark label in tabular figures; far-side sites as faint rings. Under it, scrolling: one muted hint
  line, the legend in words with the planning limits, the picked electrode (name at titleLarge, its place muted, ohms
  right in its mark's colour, its 5 s trace, then label-left / value-right rows: RMS, Mains, Last second, and the band
  strip), "Electrodes" as log rows (mark, name over its place in muted body, ohms right), where the ohms come from in a
  muted sentence, **Measure contact again** outlined, **Positions** as a text button. **Traces**: Filter and Scale as
  segmented rows with one muted sentence on what the filter does, then per channel a header row (mark, name, ohms
  right), a 76 dp trace (`track` ground, a `rule` zero line, an ink line with at most two points per pixel column),
  one muted line of numbers (flags in `caution` words) with the scale at the right, and the **band strip**: one 8 dp
  bar split by delta, theta, alpha and beta in four steps of ink (`saved`, ink-muted, ink, `rule`) with the shares in
  words under it, never colour alone. **Raw**: Pause / Back to live outlined, a slider to look back, all channels
  stacked on one `track` ground (name left, its own scale right), "Counters" and "Latest values" as label-left /
  value-right rows in tabular figures.
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
- **Was this you?** (sleep report and check-in result; `.impeccable/surfaces/app-lib-ui-wearer-view-dart.md`): a
  question leads the page, a remark ends it. When a recording did not look like the owner's usual signal, a hairline
  and the question as the page's first entry under its lead (after the honest note; on the check-in right under the
  title, before numbers that may not be his): one titleLarge ink sentence with its "i", what differed in muted
  bodyLarge with units, the everyday causes in muted bodyMedium, then **Yes, it was me** and **Someone else** as two
  equal outlined buttons side by side (stacked at large text); once answered, the same place says what the answer did
  in ink, with an Undo text button. Every other state is a remark after the page's own entries (before Past nights,
  before See trends): the hairline heading "Was this you?" with its "i", one muted sentence ("Learning what your
  brain looks like: 3 of 10 nights.", "Looks like your usual brain signal.", "Not checked: ...") and the text button
  **Someone else wore it**. No colour means anything; never a lock, a percentage or a person's name.
- **Collection ledger** (sharp hours): the watch strip's own cells counting toward the first pattern: 60 answer cells
  in three rows of 20 and 21 day cells in one row, a wider gap every five, filled `saved` as answers and days come in,
  `track` while empty; a muted label left and "26 of 60" right. Gone once the pattern opens.
- **Sharp-hours chart:** one column per block (2 clock hours, 2 hours since waking, a quarter of the sleep-pressure
  scale) on the `track` ground, the two worded ends at the left (Very sharp / Foggy, or quicker / slower), block edges
  as ticks under it; answers as ink dots side by side per level, so a count reads as a row; once the pattern opens the
  dots turn ink-muted, each block with enough answers gets its range as a `rule` band and its mean as an ink tick, and
  the named best block (or two) is outlined in ink-muted. The sentence under it says the same in words.
- **Night lane** (lucid dreams): the sleep chart's `track` lane on the night's clock, 26 dp tall, hour rules in the
  ground's colour with tabular hours under it (the plan: Lights off, +3 h, +6 h, +9 h); the cue hours a `rule` band;
  cue moments 1.5 dp `ink` ticks, `caution` amber where a stir followed; dream signals 2 dp rings above the lane (`ink`
  in dream sleep, `ink-muted` elsewhere); one muted line under it says each mark in words.
- **Night cells** (lucid dreams' test): the watch strip's cells, 12 a row with a wider gap every 4 (a block of the
  draw): faint `rule` outline ahead (sealed), `saved` when answered, `track` when not, a `ground` dot for a lucid
  morning, the next night outlined green while the cues are on; once the results open, a short `ink` bar under each
  night that had sound. The legend says it in words.
- **Board** (memory cues): a `track` field, 6 dp corners, 1 : 1.25, as wide as the column while its height fits, with
  faint `rule` hairlines in a 4 x 5 grid as a spatial reference; objects are ink Material icons at a tenth of its
  width. While learning, the answer shows the object at its place in a faint `ink-muted` ring (just outside the icon)
  with a hairline from the ring to an ink dot where you tapped; clipped to its corners. No colour tells the two halves
  apart, anywhere.
- **Drift map** (memory cues, last night and the morning result): the board with every object at its place in its
  faint ring, an `ink-muted` hairline from the ring to where it was put this morning and an ink dot there (none when it
  was put inside the ring); distances are said as % of the board's width, never millimetres; one muted line says it in
  words.
- **Task cells** (memory cues): the watch strip's own cells, one per object, two rows of 16 with a wider gap every 8,
  filling `saved` from the left as objects are seen, learned or placed, the current one outlined green; a muted label
  (Seen, Learned, Placed) left and the count right above them.
- **Choice column** (lucid dreams' morning): every morning question's answers as a vertical segmented column, full
  width, 52 dp rows, 16 dp corners, the Questions styling otherwise (one shape for the whole form; answers never wrap).
- **Try ledger** (Try these): one of the watch strip's own cells per stop, ten to a row with a wider gap after five:
  `saved` when done, a dash on `track` when skipped, the next stop outlined green like the half hour in progress,
  `track` still to come; the fill changes in 260 ms. Each stop's number cell (36 dp, growing with the text up to 130 %) repeats its mark with the number in
  tabular titleMedium (ground ink on `saved`). A stop the app ticked itself says so in words ("Seen by the app"), never
  by colour.
- **Buttons:** one filled button per screen: Start night on the night screen (Lights off while a night records), Start on the meditation screen, and on
  each training page its one step forward (Check in, Save, Agree and continue); Stop is outlined and asks once before
  stopping, except in alpha-theta, where stopping must be instant. Session faces (dream catcher, sound for states)
  are true black with words only.
- **Sound score** (sound for states): the session drawn before Start, its real minutes left to right: the quiet
  minute an empty `rule` cell, the sound's loudness a `track` band that fades in and out, the beat's rate an ink
  line (log scale, its two ends worded in Hz), minute ticks; a thin green rule where a session is, and afterwards the
  played part in `saved` with an ink rule where it ended.
- **Comparison ledger** (sound for states, "What works for you", near the end of the page for the chosen state): one
  log row per sound played, its line in bodyLarge ink and its median at the right in tabular titleMedium (the count
  "6 of 14" in ink-muted while collecting); under it the watch strip's own cells (12 dp tall, a wider gap after 7)
  filling `saved` toward 14, then, once there, a lane on one scale for every row of the state (0-45 min; half to
  double against the quiet minute with an ink-muted hairline in the middle; 1-5): `track` ground, the middle half a
  `saved` band, the median a 2 dp ink tick; the legend and "Seen together, not tested" in muted words. "A fair
  test" follows as the self-experiments' answer's place: the offer with an outlined Plan a fair test, then "Day 9 of
  28" in titleLarge, today's drawn sound in ink, "The answer opens" as a log row, Stop this test as a text button;
  afterwards the sentence in titleLarge and log rows. On a test day the Sound chips and the Length row are locked:
  the drawn ones keep their chosen look (surface-high, ink), the others fade like any disabled control, and one ink
  line above them says why. The setup is a page of chips (First sound, Second sound), Length, weeks, What counts and
  Before you start, with Start tomorrow pinned.
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
