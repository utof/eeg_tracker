---
version: 1
slug: "app-lib-ui-memory-cues-screen-dart"
primary_target: "app/lib/ui/memory_cues_screen.dart"
related_targets: ["app/lib/ui/memory_cues_view.dart","app/lib/ui/memory_task_view.dart","app/lib/ui/hands_free_view.dart","app/lib/ui/night_view.dart"]
---

# Memory cues (app/lib/ui/memory_cues_screen.dart)

Scope: memory cues in deep sleep (ROADMAP row 36, DECISIONS 500-509; the assistant's proposal, evidence weak), a
pushed page from Settings (and from a night-screen section while it is on): the switch, the evening task (objects at
places on a board, half with a soft bell, half with a soft knock; look, learn, test, then the loudness of each sound
lying down), the morning test (the same board, then "did you hear a sound?"), last night, and the self-test's sealed
result. Mode: Operate. Platform: Android (Flutter, Material 3), inside the night-watch world of DESIGN.md (inherited,
unchanged). Audience and job: the owner (not a scientist; plain short words). In the evening about 12 minutes before
Start night; in the morning 2 minutes. Constraints: dim room, tired eyes, 48 dp targets, system font scale; which
nights have sound and which half's sound plays never show; nothing claims more than the data (weak evidence; sounds
that wake you weaken the memory); the "i" note reachable. Decided without the owner (no question channel): the roll's
lead structure is taken as the choice.

Ranked structures (resonance): 1 what is due leads, deck-log column under it (the lucid page's form); 2 the board as
the spine (the learned board drawn first, the night under it); 3 the test's night bill as the spine; 4 the night's
clock lane as the spine; 5 two tabs, Tonight and Results; 6 three ritual step cards (Evening, Night, Morning);
7 a settings list (whose idea, the switch row, label-left / value-right rows, then the log sections). Dealt (seed
0861fd0440439221, surface, operate): 7 (lead), 2, 3. Kept from 2: the board itself on the page (last night's drift
map); from 3: the night cells. Challengers declined (each would replace the settled world: a type specimen, a design
annual's plates, a ticket wallet, a timetable slide rack, an acetate manual); kept from the ticket wallet: nothing
disappears, it is struck (a skipped morning test keeps its cell, dark).

## Direction contract

THESIS: A settings page that is also the experiment's log: the switch and today's two steps as plain rows, then the
board itself showing where last night's memory drifted. Refuses the category default: a brain-boost toggle with a
glowing "memory score".

OWN-WORLD: Night-watch palette and type unchanged. The board: a `track` field (6 dp corners) with faint `rule`
hairlines in a 4 x 5 grid, objects as ink Material icons. Drift map (signature move): each object's place a small
`ink-muted` ring, a hairline to where it was put this morning, the object at its place; no colour per half. Progress
as the watch strip's cells (32 in two rows, a wider gap every 8, `saved` when placed, the current one outlined green).
Log rows label-left / value-right; test cells as the lucid page's.

STORY: Whose idea and how weak the evidence, the switch, Tonight / This morning / Night of the test rows, Last night
(the drift map and its numbers), The test (cells, "Sealed until night 12", later tested apart from seen together),
How it works, Who should not use it. The task pages: one board, one instruction line, the cells; the loudness on the
ground with I hear it and Stop pinned (3 : 2).

FIRST VIEWPORT: app bar "Memory cues", Back, "i"; the muted whose-idea line; status word and sentence (Off, Learn
tonight, Ready for tonight, Test this morning, Waiting); the switch row; Tonight and This morning rows. Pinned: the
due action, filled (Turn on, Start the evening task, Start the morning test).

FORM: 7 of 7 (a settings list), with 2's board and 3's night cells. seed:0861fd0440439221

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
