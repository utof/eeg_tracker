---
version: 1
slug: "app-lib-ui-archive-screen-dart"
primary_target: "app/lib/ui/archive_screen.dart"
related_targets: ["app/lib/ui/archive_view.dart","app/lib/ui/recording_view.dart","app/lib/ui/archive_timeline.dart","app/lib/ui/archive_sheets.dart","app/lib/ui/raw_signal_screen.dart"]
---

# Archive (app/lib/ui/archive_screen.dart)

Scope: the phone's Archive (DECISIONS 700-709): the list of every recording and session by day, one recording's page
with its activity lanes, the raw signal at a moment, the tag editor, and deleting by the owner's rules. Mode: Operate.
Platform: Android (Flutter, Material 3), inside the night-watch world. Audience and job: the owner, the morning after
or during a day of recordings: see what was recorded and who started it (a button or the headband watcher), what the
app found in it, tag what he did, and delete what he does not need. Constraints: statistics stay unless "Everything"
is picked in the Danger zone; anything only on the phone is the Danger zone's, red, said plainly, asked twice; nothing
in use goes; a tone always repeats a word (lanes worded at their left); the lanes are planning values and say so.
Decided without the owner (subagent run, no question channel; the brief and the coordinator's two messages stood in).

## Direction contract

THESIS: The archive is the deck log kept by day, and a recording opens to the night's own chart grown into worded
lanes of activity. Refuses the category default: a file manager grid of cards with thumbnails and a trash icon.

OWN-WORLD: The bridge-at-night palette; the sleep chart's track lanes and hour rules; ruled log rows; label-left /
value-right rows; amber for no signal like the watch strip's gaps; `problem` red only for the Danger zone.

STORY: The owner opens More, sees today and yesterday as log rows, reads "Night · You: Start night", "Found: asleep 6 h
12 · talking 9 min", "410 MB · only on this phone"; opens the night, reads the lanes, taps a band, tags a walk, and
deletes an old test through the Danger zone's two steps.

SIGNATURE: the activity lanes: the night chart's lanes, one per activity, worded, zoomable, tapping into the signal.

FINISH: rendered at 100 and 130 % text in test/archive_screens_test.dart (build/screens/archive_*.png), DESIGN.md
"Archive", "A recording" and "Activity lanes".
