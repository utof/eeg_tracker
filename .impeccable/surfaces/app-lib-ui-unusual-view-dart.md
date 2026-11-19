---
version: 1
slug: "app-lib-ui-unusual-view-dart"
primary_target: "app/lib/ui/unusual_view.dart"
related_targets: ["app/lib/ui/trends_view.dart","app/lib/ui/trends_screen.dart","app/lib/ui/morning_section.dart"]
---

# Unusual for you (app/lib/ui/unusual_view.dart)

Scope: one section in the Trends page's single slot (right after the page's summary line, before Today) and one
optional line in the night screen's Morning section; ROADMAP proposal "Unusual for you", DECISIONS 290-299. Mode:
Operate. Platform: Android (Flutter, Material 3), inside the night-watch world. Audience and job: the owner in the
morning or during the day, glancing whether anything has been unusual for him lately, in plain words, without
alarm; noting what might explain it with one tap; switching it off. Decided without the owner (subagent run, no
question channel): the brief stood in; every choice is an assistant proposal.

## Direction contract

THESIS: a remark in the deck log. Most days it is one muted line under its heading; when a number has been beyond
your usual 2 days in a row it becomes the day's first entry, said as a sentence in titleLarge ink. Refuses the
category default: a red alert banner, a health badge, a push notification.

OWN-WORLD: the page's own parts only: the hairline heading with an "i" (as "Jaw and movement"), titleLarge ink for
the one sentence that matters, muted bodyLarge for what it is based on, the states' chips (ground, rule outline,
surfaceHigh and an ink check mark when chosen). No colour carries meaning; nothing amber or red.

STORY: heading row (title, "i", the switch: always the same place) -> the state in words -> for a card: further
numbers, what it is based on and the everyday causes ("seen together, not tested", not a diagnosis), "If you can,
take it easy today", then "What might explain it?" chips. Back in range and the pause close the loop in the same
place; Resume now is a text button.

FIRST VIEWPORT: the page's summary, then this section (about 150 dp while it learns), then Today.

SIGNATURE: the sentence itself ("Your sleep has been 2 h shorter than usual for 2 nights.").

MAIN SCREEN: only with a card, one bodyLarge ink line in the Morning section above its buttons, "Unusual for you:
..."; never at night (the section is not shown while a night records), never a notification.
