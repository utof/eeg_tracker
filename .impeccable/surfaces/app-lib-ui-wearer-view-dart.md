---
version: 1
slug: "app-lib-ui-wearer-view-dart"
primary_target: "app/lib/ui/wearer_view.dart"
related_targets: ["app/lib/ui/sleep_report_view.dart","app/lib/ui/sleep_report_screen.dart","app/lib/ui/morning_view.dart","app/lib/ui/morning_screen.dart","app/lib/ui/hands_free_view.dart","app/lib/ui/hands_free_screen.dart"]
---

# Was this you? (app/lib/ui/wearer_view.dart)

Scope: one small block on two existing pages, the sleep report and the morning check-in's result, and one section on
the Settings page (the switch); ROADMAP proposal "Was this you?", DECISIONS 370-379. Mode: Operate. Platform: Android
(Flutter, Material 3), inside the night-watch world. Audience and job: the owner in the morning, glancing at last
night or this check-in: is this recording mine; if not, keep it out of the trends with one tap; rarely, answer a soft
question. Constraints: a false question is worse than a missed one, so the words never accuse, never name a person,
never claim identity or health; a recording is never deleted; 48 dp targets; system font scale; renders at 393 dp,
100 and 130 % text. Decided without the owner (subagent run, no question channel): the brief stood in; every choice
is an assistant proposal.

## Direction contract

THESIS: a note in the deck log about who stood the watch. A question leads the page; a remark ends it. Most mornings
the check says nothing that needs the owner, so its line sits at the end of the night's (or the check-in's) own
entries, under a hairline heading with its "i": one muted sentence and a quiet text button. When a recording does
not look like the owner's usual signal, the question becomes the page's first entry under the lead, in titleLarge
ink, with two equal outlined answers; it stays there once answered, saying what the answer did, with Undo. Refuses
the category default: a red warning banner, a lock or "unknown user" screen, a confidence percentage, a face or
fingerprint icon.

OWN-WORLD: the page's own parts only: the hairline heading with an "i" (as "Jaw and movement" and "Unusual for
you"), titleLarge ink for the one sentence that asks, muted bodyLarge for the biggest difference in plain units,
muted bodyMedium for the everyday causes, outlined Material buttons side by side (one filled button per screen stays
the page's own), text buttons for the quiet actions. No colour carries meaning; nothing amber or red.

STORY: sleep report: totals, the honest note, then (only with a question) "This doesn't look like your usual brain
signal. Was it you?", what differed ("Its alpha rhythm was slower than yours usually is: 8.2 Hz, usually about
9.9."), "Loose contact, a moved headband, alcohol or a short night can change it too.", Yes, it was me / Someone
else; then the chart and the night as before. Without a question, after Jaw and movement and before Past nights:
"Was this you?" with its "i", "Learning what your brain looks like: 3 of 10 nights." and Someone else wore it.
Check-in result: the same rule around its numbers (the question right under the title, before the numbers it may
not own; the remark after the notes, before See trends).

FIRST VIEWPORT: unchanged on both pages without a question; with one, the block takes about 230 dp between the
honest note and the chart (the chart moves down, the readouts stay).

SIGNATURE: the question's one sentence and the answer that says exactly what it did ("this night is left out of
your trends, the unusual card and experiments").

SETTINGS: under the hands-free section, a hairline heading row "Was this you?" with its "i" and the switch (the
Unusual for you heading's form), the status in words ("On. Check-ins: learning, 3 of 10; nights: learning, 0 of
10."), whose idea it is, What it is, How often it is wrong (made-up people only), in the page's sentences.

FORM: a question that leads, a remark that ends (local addition inside established surfaces: no new world, no
structure roll); seed: none (unavailable: local addition).
