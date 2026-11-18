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
right after the strip. The primary action is pinned at the bottom, full width, 64 dp. The sleep report is
its own page: totals, the honest note, the chart, the periods, past nights.

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
  period log below it. No stage colours: the levels are words.
- **Sleep periods:** ruled log entries: a numbered cell, the clock span, then label-left / minutes-right
  lines (Asleep, Deep, Dream, Light), wake-ups and missing minutes as plain sentences.
- **Phone checks:** icon, one plain sentence, right-aligned text buttons that open the exact setting.
- **Buttons:** one filled button per screen: Start night on the night screen, Start on the meditation screen; Stop is
  outlined and asks once before stopping.

## Do's and Don'ts

- Do keep every value in the same place across states; the eye finds it at 3 a.m. without reading.
- Do word every state ("Recording", "No data for 52 s") next to its colour.
- Don't add bright fills, animation beyond the slow breathing live mark, or sounds. Exception: the meditation
  mode, whose feedback is sound (rain, drone, bells; DECISIONS 72-77); the night screen stays silent.
- Don't show a number that was not measured; label planning thresholds as such.
