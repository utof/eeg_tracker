---
version: 1
slug: "app-lib-ui-experiments-screen-dart"
primary_target: "app/lib/ui/experiments_screen.dart"
related_targets: ["app/lib/ui/experiments_view.dart","app/lib/ui/experiment_setup.dart","app/lib/ui/trends_view.dart","app/lib/ui/morning_section.dart"]
---

# Self-experiments (app/lib/ui/experiments_screen.dart)

Scope: the phone's Self-experiments page (ROADMAP row 14, DECISIONS rows 200-209), opened from the Trends page.
Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world. Audience and job: the
owner, once to set an experiment up in a minute (a question, ONE number, a length), then a glance a day for
today's task and one tap for "did you keep to it?", then once at the end to read a plain answer. Constraints:
the days ahead are never shown; the answer is closed until the planned day and an early look is marked for good;
"tested" and "seen together" are told apart in words; no colour alone; 48 dp targets; system font scale (checked
at 100 and 130 %); nothing bright. Decided without the owner (headless run, no question channel): the brief
stood in; every choice below is an assistant proposal.

## Direction contract

THESIS: An experiment is the watch bill for the weeks ahead: today's order of the day first, the weeks as rows of
the watch strip's own cells, and the answer's place on the page present from day 1, sealed until its date.
Refuses the category default: a habit-tracker streak calendar with a score card.

OWN-WORLD: The bridge-at-night palette, Roboto tabular figures, hairline rules. A "do" day is a filled cell
(`saved`), a "don't" day an outlined one, today outlined green like the half hour in progress, a day not kept
keeps its cell and gets a strike (nothing disappears, it cancels), days ahead are faint empty outlines.

STORY: The owner reads the status ("Day 9 of 28"), today's task in large type, answers yesterday with one tap,
sees the weeks fill, and finds where the answer will be and when. At the end the same place holds one sentence
with its range and verdict, then the counts, adherence, what was only seen together, and the honesty check.

FIRST VIEWPORT: App bar with Back, "Experiment" and an "i"; the status word; the question in one muted sentence;
"Today" with the task; the first "did you keep to it?".

SIGNATURE: the day bill: one row per week, seven day cells, sealed ahead.

FORM: the watch bill as the lead (dealt lead, position 5 of 7), fused with the sealed-answer place (7) and log
rows (4); seed 35f0ac570a3c7bfe478c9a09ab2265bc. Challengers declined (print and type-specimen worlds; the
world here is settled); kept from the ticket wallet: a cancelled state stays visible as a strike.

## Decisions made without the owner

- Setup is a page of its own with one filled button ("Start tomorrow"); a preset preselects its likely number,
  which can be changed; the length defaults to 4 weeks.
- Look early and Stop are text buttons that ask once and say what they cost.
- The Trends page gets a "Self-experiments" section (one sentence, one outlined button); the night screen's
  Morning section and the check-in's result get one muted line with today's task.
