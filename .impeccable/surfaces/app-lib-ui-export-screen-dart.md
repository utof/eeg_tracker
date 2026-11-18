---
version: 1
slug: "app-lib-ui-export-screen-dart"
primary_target: "app/lib/ui/export_screen.dart"
related_targets: ["app/lib/ui/export_view.dart","app/lib/ui/night_view.dart"]
---

# Export data (app/lib/ui/export_screen.dart)

Scope: the phone's Export data page (DECISIONS rows 150-156, ROADMAP next step 9) and its entry in the night
screen's "Your data" section. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world.
Audience and job: the owner, every few days between nights, moving everything the app keeps (nights, reports,
check-ins, sessions, dream answers) to the laptop; once, picking the folder (Download/EEG or the Syncthing
folder). Constraints: never while a night records; never deletes; a stop keeps what was copied; plain words, no
jargon beyond "folder", "file", "MB"; nothing measured about the laptop is shown (the app cannot see it).
Decided without the owner (subagent run, no question channel; the brief stood in). The structure roll ran
degraded (no challengers): dealt 7, 6, 1 of the assistant's list; 7 (the handoff route) leads, fused with 6
(progress filling as it copies) and 1 (ledger rows).

## Direction contract

THESIS: The export is a handoff along a route (this phone, the folder, the laptop), and the page says how far the
handoff has got. Refuses the category default: a settings list of toggles and a "Back up now" card.

OWN-WORLD: The bridge-at-night palette and the night screen's own parts: the status mark and word, tabular
readouts, the watch strip's track cells filling with `saved` as files copy, hairline-ruled log rows with a
numbered cell. Amber only when data sits only on the phone for 3+ days, always worded.

STORY: The owner reads one word (Up to date / 5 days behind / Never exported), sees how many files and MB are new,
checks the route rows (the folder is the one he picked), taps Export new, watches the cells fill, reads "Exported".

FIRST VIEWPORT: App bar with Back and "Export data". Status mark and word at display size, one sentence. Two
readouts: new files and their size. The copy strip (16 track cells). Then "Where it goes": three numbered log
rows (This phone, Folder with Change, Laptop). Below: Export everything with its sentence. Pinned at the bottom,
full width, 64 dp: Export new (filled), or Pick a folder before the first; Stop (outlined) while copying.

SIGNATURE: the copy strip: the watch strip's cells filling with what has reached the folder.

FORM: handoff route as the lead (dealt lead, position 7 of 7), fused with the progress strip (6) and ledger rows
(1); seed: none (unavailable).

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
