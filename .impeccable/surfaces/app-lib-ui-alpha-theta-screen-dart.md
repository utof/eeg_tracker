---
version: 1
slug: "app-lib-ui-alpha-theta-screen-dart"
primary_target: "app/lib/ui/alpha_theta_screen.dart"
related_targets: ["app/lib/ui/alpha_theta_views.dart","app/lib/ui/reaction_test.dart","app/lib/ui/training_settings_screen.dart","app/lib/ui/check_views.dart","app/lib/ui/replay_results_screen.dart","app/lib/ui/form_parts.dart"]
---

# Training pages: alpha-theta and the replay check

Scope: alpha-theta's pages (first use, setup, check-in, grounding, after-session questions, alertness check; the
session and report reuse the meditation view), Training settings with the replay check's toggle, the check's
after-session questions and its results. Mode: Operate. Platform: Android (Flutter, Material 3), inside the
night-watch world of DESIGN.md (inherited; a local addition, not a new identity).
Audience and job: the owner, reclined in a dim room before and after an eyes-closed session, possibly drowsy or
shaken afterwards. Answers a few questions, starts, stops at once if needed, comes back, answers again, checks he is
fit to drive. Constraints: plain words, 48 dp targets, system font scale, nothing preselected, the "i" note reachable,
no claim beyond the evidence notes (docs/evidence/alpha-theta.md, replay-check.md). Decided without the owner (a
subagent run with no question tool): the brief's own requirements were taken as the answers.

## Direction contract

THESIS: A session is wrapped in the same short questions every time, like a deck log's entries before and after a
watch: the same order, the same words, so the answers compare across weeks. Refuses the category default: a wellness
onboarding carousel with illustrations, mood emoji and streaks.

OWN-WORLD: the night-watch palette and type unchanged; hairline sections; amber only for a pause or a "not yet";
green only for "alert as usual", an unchanged plan and the switch that is on.

STORY: first use is one page (screening, consent, stop plan). Then: setup with the session number and length rule,
check-in, the meditation's phase track during the session, a minute of grounding with a countdown, the questions,
"Before you leave" with a still green dot to tap, the report. The replay check adds one reminder section before
the session and its questions before the report; its results open only per 12 sessions.

SIGNATURE: inherited from the meditation surface (the phase track); the reaction test reuses its still green dot.

FINISH: rendered at 100 and 130 % text (test/training_screens_test.dart, build/screens/training_*.png), looked at,
fixed; see below.

## Finish review (2026-11-18)

Disposition "fix", five findings, all applied: results values right-aligned (were floating mid-row); the results
note split into paragraphs; the reminder's section renamed "Replay check" (the reminder itself starts "Replay check
is on"); alpha-theta's report line labelled stream to ocean, not calm; one heading over the check's questions after
an alpha-theta session. Open: not seen on a phone yet; the reaction test's timing on a real touch screen is
unmeasured (the dot and the tap are both on the UI thread, a few ms).
