# Sharp hours (when in the day are you sharpest?)

## What it does

In the phone app (not yet run on a phone), and only when you switch it on: the assistant's proposal, not a feature
you asked for. A few times a day, at random moments while you are awake, a notification asks "How sharp do you feel
right now?" (one tap, 1 to 5). Two of the day's questions also suggest a 1-minute reaction test. After 3 weeks the
Sharp hours page shows your answers by the time of day, by hours since you woke and by the sleep-pressure estimate.

## Evidence for this headband: some

It does not use the headband at all: it rests on your own ratings and a tap test, which field studies show change
with the time of day and with sleep. How much they change for you, and whether your ratings change at all, only your
own weeks can show.

## What the research says

- The best-tested measure of "how good was this hour" is still a quick self-rating. In 81 software developers,
  computer app-time logs explained only about 9 % of how productive a day felt; a personal baseline and a few day
  facts (slept well, interruptions, travel) took it to 47 %.
- Logs that do work count focus sessions, not hours: a measure of runs of related work lasting 35-60 minutes matched
  what engineers wrote in diaries; total hours in focus did not.
- Self-rated productivity hardly follows the clock: in 21 developers rating every hour for 2-3 weeks, morning against
  afternoon explained 0.66 % of the ratings, mood 12 %. Another study of 20 developers found only rough, "not very
  pronounced" daily patterns after about 11 days each.
- Speed follows the clock more clearly: in 31,793 people, typing speed varied by 23 % with the time of day and 19 %
  with the time since waking up, and was lowest near the usual sleep time. Phone reaction tests in daily life swung by
  about 30 % in 20 people over 40 days.
- Two nights in a row under 6 hours went with slower performance for about six days.
- "Morning person or night owl" predicts little: over 80 % of 65 studies found no main effect of chronotype on
  thinking, and a 446-person study found no general boost from testing at your preferred time.
- An afternoon dip in performance is real and can happen even without lunch.
- The shortest reaction test validated for sleep loss is 3 minutes (the PVT-B); a 1-minute test is noisier, so the
  app uses many of them over weeks rather than trusting one.

## Where the data does not support it

- A clear best hour from ratings may never appear: the hour explains very little of how sharp people rate
  themselves. "No clear best time" is a likely and honest answer.
- What you do at an hour shapes the answer: meetings, meals, coffee, the kind of work you leave for the afternoon. The
  page shows patterns seen together, never a cause.
- Three weeks is a planning value for a first rough look; a dependable hour-by-hour curve needs months.
- You rate how you feel, and feeling can disagree with doing: developers in one trial believed an AI tool made them
  20 % faster while it made them 19 % slower.
- Answers you give only when it suits you lean the pattern: that is why the questions come at random moments, and a
  rating from the page is marked as such.
- Not tested on anyone yet, including you. The phone's delivery of the questions (HyperOS can hold notifications back)
  is checked by the page itself, not proven.

## How the app uses this

- Off until you switch it on (Trends, then Sharp hours). The page says it is the assistant's idea, and it can be
  switched off or deleted there.
- Questions: 4 a day (or 3 or 6) inside your waking hours (suggested from your recorded nights: from 30 minutes after
  your usual wake-up to an hour before your usual sleep; else 10:00 to 22:00). The waking hours are cut into equal
  parts and each part gets one random minute, at least an hour apart, so each day has early and late answers to
  compare and no hour is asked more than another over the weeks. Two a day suggest the reaction test.
- Never during a night recording, a sound session or a session on screen, and never in the quiet hours. A question
  that arrives over an hour late is dropped; one you miss disappears after an hour; "In 15 min" puts it off once.
- One tap saves "how sharp" on 1 Foggy, 2 Slow, 3 Okay, 4 Sharp, 5 Very sharp, at the time you answer. The reaction
  test is the app's 1-minute test: a dot after 2-5 seconds, tap fast; the median of at least 5 taps.
- Collecting: for the first 3 weeks and about 60 answers the page shows only the dots and how far it is from a first
  pattern. Reaction times need 30 tests as well.
- Then, by 2-hour blocks of the clock, of hours since waking, or of sleep pressure: each block's mean with a range
  that holds 80 % of means when whole days are drawn again at random. A best time is named only when the same block
  (or it and its neighbour together) beats every other block in 9 of 10 of those redraws and is half a point better
  (5 % quicker for reaction time). Everything is labelled "seen together, not tested".
- Trends shows the day's mean sharpness and the middle of the day's reaction tests; self-experiments can test either
  as the next day's number.
- Computer focus sessions (ActivityWatch) belong to the laptop and are not part of this yet.

## Sources

- [Beller 2020: measured against self-reported productivity](https://arxiv.org/abs/2012.07428)
- [Brown 2023: focus sessions from logs](https://arxiv.org/abs/2304.04711)
- [Girardi 2021: emotions and perceived productivity of developers](https://aserebre.win.tue.nl/TSE2021.pdf)
- [Meyer 2017: the work life of developers](https://Www.Gwern.net/doc/psychology/writing/2017-meyer.pdf)
- [Althoff 2017: sleep, time of day and performance in 31,793 people](https://arxiv.org/abs/1701.07083)
- [Abdullah 2016: cognitive rhythms with a phone reaction test](https://depts.washington.edu/chilllab/?p=405)
- [Visuri 2025: phone reaction tests and sleep over two months](https://arxiv.org/abs/2501.15583)
- [de Jong 2020: typing slows with time on task](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0239984)
- [Chauhan 2025: chronotype and cognition, 65 studies](https://bura.brunel.ac.uk/bitstream/2438/31067/6/FullText.pdf)
- [Rey-Mermet 2023: no general synchrony boost](https://doi.org/10.1525/collabra.88337)
- [Monk 2005: the post-lunch dip](https://pubmed.ncbi.nlm.nih.gov/15892914/)
- [Basner 2011: the 3-minute PVT-B](https://pmc.ncbi.nlm.nih.gov/articles/PMC3197786)
- [METR 2025: believed faster, measured slower](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/)

## Libraries and models

- This project's own sampling schedule, resampling ranges and reaction test (MIT); Android's alarm and notification
  services, no extra library.

Checked: 2026-11-19
