---
version: 1
slug: "app-lib-ui-night-screen-dart"
primary_target: "app/lib/ui/night_screen.dart"
related_targets: []
---

# Night screen (app/lib/ui/night_screen.dart)

Scope: the recorder app's only screen. Mode: Operate. Platform: Android (Flutter, Material 3).
Audience and job: one tired person at bedtime and on waking (and half-asleep at 3 a.m. after a drop)
starts the night, checks contact, trusts that recording is happening, stops in the morning, fixes phone
settings once. Constraints: dark bedroom, eyes dark-adapted; 48 dp targets; system font scale; nothing
bright or blinking. Decided without the owner (asleep, no question channel): every choice below is an
assistant proposal under DECISIONS row 14.

Physical scene: lying in a dark bedroom at 23:30 or 03:00, phone at arm's length; a bright field glares
and wakes the user, so the screen is dark, warm and low-luminance.

Ordered grounded list (resonance): 1 bedside alarm clock (dim amber numerals); 2 darkroom safelight /
astronomer's red mode; 3 sleep-lab night-tech console; 4 hospital ward night observation chart;
5 night sleeper-train timetable; 6 moon and tide almanac; 7 a ship's bridge on the night watch and its
deck log (assigned by the roll).

Challenger verdicts (all declined; kept discipline in brackets): split-flap concourse [values sit in fixed
cells, columns never move]; doujin catalog [whole-cell marks, state by fill not colour alone]; orienteering
map [one hue reserved for the single live element]; acetate tab board [one ply only, no nested cards];
Saville sleeve [quiet black field, one figure owns it]; Japanese high-density [hairline rules group,
not boxes].

## Direction contract

THESIS: The night is a watch being kept, logged half hour by half hour, so the user sees at a glance
that nothing is missing. Refuses the category default: a fitness-style dashboard of metric cards.

OWN-WORLD: Bridge-at-night palette: warm chart-table black ground, parchment ink, the navigation-light
trio dimmed for dark-adapted eyes (starboard green = live and good, amber = caution, port red = problem).
Roboto with tabular figures; deck-log rhythm of ruled rows with times; hairline rules, one surface ply,
no cards, no glow.

STORY: The user reads one word (Recording), sees minutes and data age, sees the night's half hours
filled, trusts it, puts the phone down. Problems appear as plain rows with one button each.

FIRST VIEWPORT: Top: small title. Upper third: phase word at display size with a live mark, one plain
sentence under it. Then two big tabular readouts (minutes recorded, seconds since data) split by a
hairline. Then the watch strip: half-hour cells in rows of four hours, the current cell outlined green.
Headband facts and contact marks below; phone checks follow. Primary action pinned at the bottom,
full width, 64 dp: Start night (filled green) or Stop (outlined, confirmed).

SIGNATURE: the watch strip; each half-hour cell fills with the share of samples actually saved, so gaps
show as hollow cells.

FORM: ship's bridge on the night watch and its deck log, position 7 of 7; seed:a24d111eb0ab99e7.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

LIGHTS OFF (2026-11-19, DECISIONS 180-186; no question channel, the brief stood in for the owner): while a night
records, the pinned bar gains Lights off beside Stop (3 : 2), the night's one filled button until tapped, then an
outlined "Lights off again" in the same place that asks first; one muted line above the buttons says what the
drift-off detector thinks, in words only; a hairline sets the bar apart from the page under it. Placed in the bar
because it is used lying down at the moment the eyes close, where the thumb already is. Refused: a section in the
scrolling page, a notification action, a coloured state chip. Checked as test renders at 440 dp (100 and 130 %
text) and at the owner's 393 dp with 130 % text, which also found the watch strip 6 dp too wide (fixed).

## Addition 2026-11-19: Share on Wi-Fi (DECISIONS rows 220-229)

A narrow addition inside this surface, no new direction (headless run, the brief stood in for the owner): in "Your
data", under a hairline, a switch row "Share on Wi-Fi" with one sentence and, while on, "Address and code", which
opens a sheet (`app/lib/ui/share_sheet.dart`): who can read and that it is not encrypted, Address / Code / Turns off
at as log rows, a parchment QR code, the two laptop commands, New code. During a night the section holds only this
row. Checked as test renders at 100 and 130 % text (`app/test/export_screens_test.dart`), not on the phone.

SMART ALARM (2026-11-19, DECISIONS 230-239; no question channel, the brief stood in for the owner): set where the
night is started: one muted line with a sunrise icon above Start night under a hairline, "Smart alarm off." with Set
alarm, or "Wakes you by 07:30 tomorrow, from 07:00 at a light moment." with Change, opening a sheet (the wake-by time
as a big tabular figure, the window 15 / 20 / 30 / 45 min, two sentences of the rule and the safety net, Alarm off and
Set alarm). While a night records the bar gains a second muted line under the Lights off line with Alarm off (asks
first); the stages in words, never colours. While it rings the whole screen is the nap coach's wake face, "Time to
wake up" and one I'm awake filling the screen; the same page is native Android over the lock screen
(AlarmActivity.kt). Refused: a section in the scrolling page (set at bedtime, next to Start, not scrolled to); a
clock-face dial; a stage chip in colour; a snooze button (the window already is the snooze). Checked as test renders
(build/screens/alarm_*.png) at 440 dp with 100 and 130 % text and at the owner's 393 dp with 130 % text.
