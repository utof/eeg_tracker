# Study timing (evening study, morning review)

## What it does

In the phone app (not yet run on a phone), and only when you switch it on in Settings: the assistant's proposal, not a
feature you asked for. A reminder in the evening, 1 to 2 hours before your usual bedtime ("Good time to learn
something you want to keep"), and one in the morning, 30 to 60 minutes after you usually wake ("Try to recall what you
studied last night, before looking"). One tap each way records "studied tonight: yes or no" and "recalled: well, some
or a little". It does not teach anything and does not use the headband.

## Evidence for this headband: some

The headband plays no part. What backs the idea is one small study of evening learning followed by a morning review,
plus general findings on sleep and memory; the effect for you, and for your kind of material, is unknown, and the app
can only help you look at your own days.

## What the research says

- The main study (Mazza 2016, 40 people, 16 foreign-language word pairs): people who learned in the evening and
  relearned the next morning needed about half the practice to get every pair right again (3.05 against 5.80 tries),
  remembered more a week later (15.2 against 11.3 of 16) and still more at 6 months (8.7 against 3.4 of 16), than
  people who learned in the morning and relearned in the evening.
- Those numbers are very large and come from small groups of 20, so the true effect is probably smaller. The two groups
  also learned at different times of day (the authors checked sleepiness and morning or evening type and found no
  difference), and nobody's sleep was recorded.
- Naps help remembering facts a little: across 54 studies the effect was small to medium (a standardised difference of
  about 0.38).
- "Sleep improves practised skills" (such as finger-tapping sequences) largely disappears once the studies' design
  flaws are removed, so this note makes no claim about skills.
- No study of sleep and programming skill was found, and none of a reminder like this one.

## Where the data does not support it

- The reminder is not the research. In the study people learned, slept and relearned to a set goal; a notification and
  a self-rating are the app's own way to nudge the same order, and nothing shows the nudge changes what you do or what
  you remember.
- "Recalled: well, some or a little" is how you feel it went, not a test. People misjudge their own memory in both
  directions, so use it to compare your own days, not to grade yourself.
- Why the morning step is "recall first, then look" is the app's design, not the study's (which was relearning). The
  research this project read did not cover recall practice or spacing, so the note makes no claim about them.
- The best gap between studying and bed was not researched. 1 to 2 hours before bed is a planning value, and what you
  study (the study used word lists) may behave differently.
- Whether studying late costs you sleep was not researched here. The app does not know what or how long you study:
  keep to what you would do anyway.
- Seen together, not tested: days you study in the evening may differ in other ways (a calm day, more energy). The
  self-experiment "Study in the evening or the morning" (Trends, Self-experiments) draws the days at random and compares your
  recall the next morning. On a morning-study day the recall comes 24 hours after studying, not 12, which can favour
  the evening; the experiment cannot remove that difference, so keep it in mind when you read its answer.

## How the app uses this

- Off until you switch it on (Settings, Study reminders). The page says it is the assistant's idea, and it can be
  switched off or deleted there.
- Times: the evening reminder 90 minutes before your usual bedtime, rounded down to the quarter hour; the morning
  reminder 45 minutes after your usual wake-up, rounded up to the quarter hour. "Usual" is the middle of the last 14
  days of recorded sleep, from 3 nights; until then 21:00 and 08:30. You can set either time by hand and go back to
  following your sleep.
- Never in the quiet hours: automatic times are moved inside your waking hours (the Sharp hours window if you have one
  saved, else the one your sleep suggests), and a time you set must be inside them. Never during a night recording, a
  sound session or a session on screen: the reminder is skipped and logged. One that arrives over an hour late is
  dropped; one you miss goes after an hour; "In 15 min" puts it off once.
- The reminders use the same alarm setup as Sharp hours: no exact-alarm permission, so they can be a few minutes late,
  and on a Xiaomi they need Autostart and no battery limits.
- Say "no" to "Did you study something tonight?" and the next morning's reminder is skipped (nothing to recall); "Not
  yet" leaves the question for later on the page.
- The log: tonight's yes or no and the morning's well, some or a little, kept only in the app's private folder and
  taken by Export data. Trends shows the day's recall (1 a little, 2 some, 3 well; the mean of the day's answers), and
  a self-experiment can use it as its number.

## Sources

- [Mazza 2016: sleep after evening learning, morning relearning, 6-month follow-up](https://doi.org/10.1177/0956797616659930)
- [Leong, Lo and Chee 2022: naps and memory, 54 studies](https://medicine.nus.edu.sg/newsletters/issue45/science-of-life/how-naps-can-be-beneficial-for-you)
- [Pan and Rickard 2015: sleep and motor sequence learning](https://doi.org/10.1037/bul0000009)

## Libraries and models

- None beyond this project's own schedule and log (MIT); Android's alarm and notification services share the Sharp
  hours setup, no extra library.

Checked: 2026-11-19
