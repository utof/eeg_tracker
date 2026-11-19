---
version: 1
slug: "app-lib-ui-try-these-screen-dart"
primary_target: "app/lib/ui/try_these_screen.dart"
related_targets: ["app/lib/ui/try_these_view.dart","app/lib/ui/night_view.dart"]
---

# Try these (app/lib/ui/try_these_screen.dart)

Scope: one page, opened from a "Try these" section on the night screen between nights (after Morning; the night
screen's change stays one line in `night_view.dart`), plus that section's one line and button. The page lists each
feature's first try as a numbered stop in a sensible order, with what it is, what to do, what to tell the assistant,
how long it takes, a button to that feature's screen, Done / Skip and an optional note saved app-private and exported
with Export data (DECISIONS 340). Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world.
Audience and job: the owner (not a scientist; tired; plain short words), a few minutes before or after a try, finding
what to try next and what to tell the assistant afterwards, instead of reading app/README.md. Ranges: 20 stops
(17 from the README's owner steps, meditation, alpha-theta, the replay check); 0 to 20 done; a note from empty to a
few paragraphs; 3 of the stops are the assistant's proposals. Decided without the owner (subagent run, no question
channel and no decision page anyone could answer; the brief stood in).
Structure roll seed:8695f834486d4c7c, operate, dealt 7, 4, 5 of the assistant's list (1 ledger + next stop open,
2 one stop at a time, 3 a numbered accordion route, 4 grouped by when, 5 a day-by-day plan, 6 tabs To try / Done,
7 report-first stops); the dealt lead is built, fused with 4 and 5. Challengers weighed and declined (the world is
settled, so a palette or chrome change is out): airport yellow wayfinding (kept: only the next decision is open, its
time as the distance, and the page re-signs itself after each turn), orienteering map (kept: each stop's number is
fixed like a control number, and a punched stop fills its cell), boarding pass and gate board (kept: a done stop
leaves the board for the Done list), metro tiles, streaming title wall, split-flap board (costumes on a working page).

## Direction contract

THESIS: a tour that ends in a report. Each try is one numbered stop; the open stop closes on what to tell the
assistant and a note that leaves the phone with Export data. Refuses the category default: an onboarding checklist of
checkbox rows under a percentage ring, with confetti.

OWN-WORLD: the night-watch palette and parts only: the try ledger in the watch strip's own cells (one per stop: filled
`saved` when done, a dash on `track` when skipped, the next stop outlined green like the half hour in progress);
stops as hairline log rows with a numbered cell like the export route; group headings by when; the proposal said in a
muted sentence; the dream catcher's underline note field; Done is the page's one filled button (only the open stop has
it), Skip a text button.

STORY: the owner reads "4 of 20 tried", sees the cells, finds the next stop already open: what it is, the steps, the
button to its screen; does it; comes back, reads what to tell the assistant, types a line if he likes, taps Done. The
page re-signs: the stop folds into "Done and skipped" and the next one opens.

FIRST VIEWPORT: app bar with Back and "Try these"; the tally ("4 of 20 tried" in titleLarge ink, "1 skipped" muted)
over the ledger (two rows of 10 cells, a wider gap every 5); one muted sentence on how it works; the first group
heading ("Tonight, then the morning") and the next stop open: its number cell and title at titleLarge, the time and
(for a proposal) "The assistant's idea" in muted body, the one-sentence what, then the steps begin.

SIGNATURE: the ledger and the re-sign: Done folds the stop away and opens the next, its cell going from a green outline
to filled.

FORM: report-first stops (dealt lead, 7 of 7), grouped by when (4) in the order of a first week (5); seed:8695f834486d4c7c.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Finish review (2026-11-19)

A fresh reviewer agent (no shared context, Opus) judged the test renders against this contract, DESIGN.md and the
craft floor. First round: recapture (the "_full" shots had a fixed height that cut three states, and the open states'
first screens did not scroll to the open stop); the capture test now sizes full shots to the content and fails when
anything is left below, and scrolls the open stop to the top. Second round: fix, five material findings, all applied
and scored resolved in the verdict pass, disposition ship: a "What happened" label over the note (hint "Optional. Goes
out with Export data."); Open Export data under the sentence once every stop is finished; the number cell follows the
text size up to 130 %; a fixture date that did not match its weekday; captures of the main screen's line once read.
Kept as the reviewer asked: the ledger in the watch strip's cells with the green-outlined next stop, and one open stop in
hairline rows ending on what to tell the assistant, the note and the one filled Done.
