# How the app asks

## What it does

The quick checks are built so that your answers stay careful for months. Five things do that:

- **The words.** A card says the stretch first and the guess second, as the headband's opinion: "15:59-17:49. The
  headband thinks you slept. Did you?" The buttons name the thing: "I slept", "I was awake", "Not sure", always in
  that order.
- **The times are a separate question.** A plain "I slept" means "it happened", not "these start and end times are
  right". A small "Yes, but the times are off" opens the stretch on a strip where you move both ends.
- **Blind cards.** About 1 card in 5 does not show the guess: "What were you doing 19:08-21:14?" with a few choices
  and your own words.
- **A small budget.** At most 2 notifications a day with at most 4 cards each, never while you usually sleep. Anything
  more waits on the card in the app. Old or short stretches are dropped instead of asked late.
- **Backing off.** If you often leave the notifications unanswered, the app sends fewer by itself.

## Evidence for this headband: some

The rules come from studies of surveys, phone prompts and people checking a machine's guesses. None of them tested a
headband asking its wearer, and none tested these exact numbers. Every number here is a starting value. A small
monthly check on your own answers (below) shows whether they need changing.

## What the research says

- **How often you are interrupted matters more than how many taps.** In a study of 163 students, more prompts a day
  (3, 6 or 9) made answers more careless day after day; longer forms did not. One-tap questions were still answered
  after a year in a study of 177 people.
- **Showing a guess pulls answers toward it, mostly where you cannot check it.** In a study of 2,784 people checking
  a machine's values, easy errors were caught about 80 % of the time and hard ones only 21-31 %. You know whether you
  walked this evening. You do not know that it was 19:08 to 21:14. So a Yes is kept as "it happened" only.
- **A bare Yes/No draws more Yes.** In survey experiments the same item got 1.42 times more "yes" as a Yes/No
  question than as a list to tick. Buttons that name the thing reduce agreeing by default.
- **Answering before seeing the machine's answer reduces following it.** In a study of 199 people it cut following
  wrong advice from 0.64 to 0.48. People liked it less, so only 1 card in 5 is blind.
- **Times fade fast, "did it happen" lasts.** An evening diary missed only 4-8 % of activities, but its times were
  rounded to 5 or 10 minutes; stretches rebuilt the next day came out longer (110 against 80 minutes). Details lost
  about 1.3 % accuracy per hour in a 14-day study. A picture of the timeline helped and stopped that loss.
- **"Not sure" is information.** Offering "don't know" greatly reduced made-up answers in a study of 1,288 people.
  Whether a prompt is answered at all is not random either: a person's own past answer rate predicts it best.
- **Habit turns into autopilot.** People interviewed after a 12-month study said they answered fast and the same
  way; an odd question now and then broke that and they found it helpful.
- **Feeling surer is not being right.** With a suggestion on screen, 410 annotators felt more confident and were no
  faster. So there is no "how sure are you" slider.

## Where the data does not support it

- No study covers two apps asking one person, or a wearable asking its wearer to confirm what it detected.
- The cut-offs (48 hours, the same day for times, 15 minutes and 3 hours, 1 card in 5, the 50 % and 25 % answer
  rates, 7 days, 10 batches, about 1 second) are reasoned from the studies' direction, not measured. They are
  starting values, each a single number in the code.
- A fast Yes is not proof of carelessness, and a normal answer rate is not proof of care. The monthly check gives
  hints, not proof.

## How the app uses this

- **Yes** is kept as "it happened". The times stay the headband's guess, marked as not confirmed, so nothing later
  treats them as fact. **"Yes, but the times are off"** keeps your times, marked as confirmed (also when you looked
  and left them). It is offered only on the day of the stretch; later the card asks only whether it happened, with
  the times to the half hour.
- **Not sure** is kept as its own answer. It is not a fact, it is never asked again, and nothing that trains or
  scores a detector sees it. **No answer** (a notification swiped away, a question that got too old) is kept
  separately and is never read as Yes or No.
- **Blind cards** store what you said. The guess is stored too but not shown; whether you agreed is worked out
  later. Which card is blind is fixed by the stretch itself, not rolled each time.
- **Budget:** 2 notifications a day (it was 3), 4 cards each. The questions after Stop never count. Anything more
  waits on the card in the app, with a number on the Record tab.
- **Dropped unasked:** stretches older than 48 hours, and stretches under 15 minutes once they are 3 hours old.
- **More than 4 waiting:** a notification takes the 2 newest and the ones the headband is least sure of. The rest are
  not pushed, but they stay on the card in the app until you answer them or they are 48 hours old.
- **Quiet hours** follow your real sleep once the app has 3 of your nights: from your usual bedtime until 30 minutes
  after you woke. Before that, and whenever you switch "Follow my sleep" off, the fixed hours apply (22:00-08:00
  unless changed).
- **Backing off:** under half of the week's notifications answered: 1 a day. Under a quarter: none for 7 days, then
  1 a day again. Two swiped away in a row in the same hour: that hour is skipped for 7 days. Ten in a row all Yes
  within about a second a card: the next one is blind cards. Each step is written to the phone's files with its
  reason.
- **The monthly check** (`scripts/asking_check.py` on the laptop) prints three small tables from your answers: the
  Yes rate against how sure the headband was, blind cards against cards with the guess, and how often you say "Not
  sure" by kind and by age of the stretch.

## Sources

- [Ulitzsch and others 2025, careless answers and how often people are asked](https://doi.org/10.1037/pas0001379)
- [Ponnada and others 2025, one-tap prompts over a year](https://pmc.ncbi.nlm.nih.gov/articles/PMC12439519/)
- [Beck and others 2025, people checking a machine's values](https://arxiv.org/html/2509.08514v1)
- [Callegaro and others 2015, Yes/No against tick-lists](https://research.google/pubs/yesno-answers-versus-check-all-in-self-administered-modes-a-systematic-review-and-analyses/)
- [Buçinca and others 2021, answering before seeing the machine's answer](https://ar5iv.labs.arxiv.org/html/2102.09692)
- [Schroeder and others 2025, suggestions and confidence](https://arxiv.org/abs/2507.15821)
- [Hoelzemann and Van Laerhoven 2024, diaries, buttons and a timeline](https://www.frontiersin.org/articles/10.3389/fcomp.2024.1379788/full)
- [Cobb and Gross 2025, same-day against next-day recall](https://cml.hci.uni-bamberg.de/~gross/publ/chira25_cobb_gross_esmtypes.pdf)
- [Rabbi and others 2019, recall fading by the hour](https://mashfiqui-rabbi.github.io/files/revibe2019.pdf)
- [Andersen and others 2023, offering "don't know"](https://ojs.ub.uni-konstanz.de/srm/article/view/7943)
- [Reiter and Schoedel 2023, who answers a prompt](https://pmc.ncbi.nlm.nih.gov/articles/PMC11133120)
- [Wang and others 2024, answering as a habit after 12 months](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11329843/)

Checked: the numbers are from the project's research note of 2026-11-24 (asking well), which read these pages or
their abstracts. That note marks which it only saw as search summaries; none of those is used here.

## Libraries and models

- No model and no new library.
