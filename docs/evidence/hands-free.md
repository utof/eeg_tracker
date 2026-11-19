# Hands-free controls

## What it does

Off unless you turn it on. A deliberate double jaw clench (two short clenches 0.3-1.5 s apart, then nothing for 2
seconds) or a look left, then right, works as a switch during a session: pause or resume the sound, mark a moment,
or answer "were you drifting?". A short calibration sets the levels for your head.

## Evidence for this headband: some

Jaw clenches at T3/T4 are among the clearest things this headband sees, and jaw and eye switches near the ears work
in small lab studies; but no study has tested them as switches on this headband, almost none counted false
triggers over hours of real use, and telling left from right is the weaker part (62% on this headband in one study).

## What the research says

- Muscle switches (EMG: the muscle signal) work, but fire by accident more often than buttons. In 12 people with
  disabilities trying a dry-sensor muscle switch, the 8 who also used a button never had fewer accidental presses
  with the muscle switch; the one person wearing it on the jaw made 2.9 presses for every intended one (button: 1).
  A European gaze-control report adds that coughing or laughing raises the muscle signal and can fire one or more
  clicks.
- A single clench is a poor switch: temple-muscle recordings in 34 people found 33.6 clench episodes an hour by day,
  and 23% of people who thought they did not clench did.
- Asking for a pattern of actions, like a wake word, cuts false triggers to near zero at the cost of misses. A
  triple tooth tap, sensed by motion and sound in an earpiece, gave no false triggers in 71.5 minutes of 11 people
  talking, writing, walking and eating, but missed 23 of 133 real taps (17%). A forearm muscle "wake gesture"
  ignored over 99.9% of everyday movements and missed 19-25% of real ones; people preferred misses to false
  triggers. A commercial earbud (Wisear) chose a double jaw clench for pause and resume; about 80% of people at a
  trade-show demo made it work, with no false-trigger numbers published.
- Eye switches (EOG: the eye-movement signal) show the same: in separate lab studies (not a fair head-to-head),
  a single blink falsely fired 0.18 times a minute (about 11 an hour), a double blink 0.26-0.74 a minute (16-44 an
  hour, 16 people), and a triple blink 0.01 a minute (under 1 an hour, 11 people). The authors warn that tired
  users may mix up deliberate and automatic blinks.
- Near the ears: headphones with six dry electrodes around the ears told left glance, right glance, jaw clench and
  rest apart 94% of the time (97% with a model trained on the person) in 19 healthy people steering a simulated
  wheelchair. In another ear-electrode study (16 people) a 15° sideways glance swung about 40 µV, while up and down
  were unusable. On this headband, 22 people's eye jumps were found 90% of the time, but left was told from right
  only 62% of the time (50% is guessing); those were small natural eye movements at a screen, not big deliberate
  glances.
- The "Midas touch" problem (the king whose touch turned everything to gold): eyes move all the time without
  meaning anything, so an interface that acts on every look soon fires everywhere. The classic fix is to ask for
  something deliberate, such as holding the look or a second action; a long hold avoids accidents but feels slow,
  and a short one is fine only when a wrong pick is undone at once.

## Where the data does not support it

- No study has tested jaw or eye switches on this headband, and none measured false triggers over hours of real use
  (the longest everyday test above was 71.5 minutes across 11 people). The app's own check is one recorded night
  and one morning check-in where nobody made a gesture (below); whether it catches your real gestures is unknown
  until your calibration.
- Left versus right is the weak part on this headband (62%). Big deliberate glances should be clearer than the
  small movements in that study, but that is untested here. In the headphone study the dry electrodes needed 10-20
  minutes to make good contact, and the failed commands all came with poor contact.
- Drowsiness fakes the eye gesture: while drifting off, the eyes make slow, rolling, mostly sideways swings (20-200
  µV, each taking 1-10 seconds). They belong to drowsy waking and the lightest sleep and grow in the minutes before
  deeper light sleep, so they come while you may still count as awake. On T3 minus T4 they look like left-right
  glances, just when a dream-induction session asks "were you drifting?". They are slower than a deliberate glance,
  which may help tell them apart, but that is untested; a glance answer near sleep is not reliable.
- Sleep fakes the jaw gesture: nearly 60% of healthy sleepers show rhythmic chewing-muscle bursts in sleep (1-6
  episodes an hour on average in young adults), and people swallow about 2-6 times an hour asleep in different
  studies, almost always (98%) during a brief awakening. No numbers were found for jaw twitches in dream sleep in
  people.
- Coughing, laughing, talking and chewing also light up the jaw muscle band; the quiet time around a
  double clench is meant to reject them, but that has not been measured.
- Most numbers come from healthy young adults sitting still in a lab, often with gel electrodes; one jaw-clench
  detector on wet ear electrodes was right only 72% of the times it said "clench" against 26 other face movements
  (one person).

## How the app uses this

- Off until you switch it on in Settings (the gear on the main screen). Switching on first runs the calibration,
  about 90 seconds with the headband: 30 seconds sitting still, then three "clench twice now" and three "look left,
  then right", each on a soft tone. It sets the clench line at half your weakest calibrated clench (kept between 10
  and 60 times your resting level), the look size at 0.6 of your smallest calibrated look (70-250 µV), and which way
  is left when all tries agree. A gesture is used only if at least 2 of its 3 tries were caught.
- Double clench: two bursts of 0.2-1 s, 0.3-1.5 s apart, with both temple electrodes over the line at each burst's
  strongest tenth of a second; no other jaw muscle (both sides up) for 2 seconds before and after, and no movement
  or lost signal. Muscle is the 55-120 Hz band every 0.1 s against the detectors' own resting level (the quietest
  fifth of the last 2 minutes).
- Look left, then right: two opposite steps of T3 minus T4 of at least the look size, each within 1.5 s of the one
  before (a third, back to the middle, may follow), and no other eye movement for 2 seconds around. Once left is
  known the first step must go left; until then either way counts ("look away and back"). The steps are changes
  over 0.1 s, so the slow drowsy eye rolls above mostly do not count; untested.
- What they do: Sound and Meditation: a double clench pauses the sound and the next brings it back; a look marks a
  moment. Dream catcher: while "were you drifting?" waits, a double clench answers Drifting (a nod) and a look
  answers Awake (a shake of the head); otherwise a moment. Alpha-theta and the nap coach: a moment. The night
  recording: only the double clench, as a moment marker without a tone (dream sleep is full of left-right eye
  movements).
- A soft tone confirms each gesture, 2-4 seconds after it (the app waits for the quiet 2 seconds). Gestures are off
  while the drift-off detector says you are probably asleep (except while the dream catcher's question waits for
  its answer: the question has just woken you), and never in the morning check-in, so they cannot change its
  measurement.
- Checked where nobody made a gesture, at the first-guess settings (line 10 times rest, looks of 80 µV either way):
  on one recorded night, awake 4.6 hours: no double clench and 9 looks (about 2 an hour; about 1 an hour with left
  known); asleep 6.5 hours: 4 double clenches and 4 looks (about 0.6 an hour each); a 5-minute morning check-in:
  none. With a clench line of 40 times rest or more, none came up asleep either.

## Sources

- [Dry-sensor muscle switch in 12 users (Judge 2025)](https://eprints.whiterose.ac.uk/id/eprint/226714)
- [COGAIN report on muscle switches with gaze (2009)](https://www.wiki.cogain.info/images/d/d1/COGAIN-D4.9.pdf)
- [Daytime clenching (Yoshida et al. 2024)](https://www.jstage.jst.go.jp/article/josnusd/66/1/66_23-0362/_article)
- [TeethTap: triple tooth tap as a wake gesture (Sun et al. 2021)](https://arxiv.org/abs/2102.12548)
- [Wake gestures against false triggers (Eddy et al. 2024)](https://ar5iv.labs.arxiv.org/html/2402.10050)
- [Wisear double-clench earbuds (TechCrunch 2022)](https://techcrunch.com/2022/01/20/wisear/)
- [Triple-blink switch, single-blink comparison (Zhu et al. 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7714925)
- [Double-blink switch (Wang et al. 2022)](https://pmc.ncbi.nlm.nih.gov/articles/PMC8957419)
- [EarEOG: dry headphone electrodes, glances and clench (Liu et al. 2025)](https://www.yorku.ca/mack/etra2025.html)
- [Sideways glances on ear electrodes (King et al. 2025)](https://arxiv.org/html/2506.07193v2)
- [Eye direction on this headband (Romaniuk & Kashevnik 2024)](https://fruct.org/files/publications/volume-36/fruct36/Rom.pdf)
- [The Midas touch problem (Jacob 1991)](https://marcjohnson.fr/wp-content/uploads/2020/12/1991-Jacob-The-Use-of-Eye-Movements-in-human-computer-interaction-techniques.pdf)
- [Slow eye movements while falling asleep (Cona et al. 2013)](https://www.scitepress.org/Papers/2013/45513/45513.pdf)
- [Chewing-muscle bursts in normal sleepers (Lavigne et al. 2001)](https://read.qxmd.com/read/11332529/rhythmic-masticatory-muscle-activity-during-sleep-in-humans)
- [Chewing-muscle bursts per hour in young adults (Haraki et al. 2019)](https://read.qxmd.com/read/30703175/sleep-quality-psychologic-profiles-cardiac-activity-and-salivary-biomarkers-in-young-subjects-with-different-degrees-of-rhythmic-masticatory-muscle-activity-a-polysomnography-study)
- [Swallowing in sleep comes with awakenings (Burke et al. 2020)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7165485)
- [Swallows per hour asleep, earlier studies (Ito et al. 2024)](https://www.jstage.jst.go.jp/article/fmj/10/2/10_2023-010/_html/-char/en)
- [Jaw clench against 26 face movements, wet ear electrodes (Knierim et al. 2022)](https://pmc.ncbi.nlm.nih.gov/articles/PMC9529594)

## Libraries and models

- This project's own detectors and gesture rules (MIT; `analysis/hands_free.py` and its line-by-line phone port); no
  machine-learning model.

Checked: 2026-11-19
