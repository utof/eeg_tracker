# When I put the headband on (automatic recording)

## What it does

In the phone app (not yet run on a phone; first phase). When the headband is on, the app notices and starts the night
recording or a work session by itself, or asks you first with one quiet notification, or does nothing: your choice,
separately for the night, work and anything else ("Ask me" at first).

## Evidence for this headband: some

Telling "on the head" from "on the table" by the electrodes' contact is near certain once tested on a head; telling
"going to sleep" from "working" comes from the clock, the phone and the laptop, which studies of phone use support for
sleep timing. What you are doing beyond that (meditating, focused, stressed) cannot be read from these four electrodes,
so the app asks instead.

## What the research says

- No EEG headband found starts recording by itself when you put it on: Muse, Dreem, Elemind, Neurable and BrainBit's
  own app all start with a tap or a button, and each runs a short signal check first. The pattern copied here is the
  fitness watches': they notice a workout, ask "record this?", and count it from when it really began.
- BrainBit has no on/off switch and stays in standby for up to a month, so "the phone sees the headband" does not mean
  "it is on your head". Its battery is rated "up to 10 hours"; one user reports less.
- Off the head, the electrodes' contact reads as infinite resistance (seen on this project's headband), so a few
  seconds of contact reading tell worn from not worn.
- When you go to sleep can be read from phone use alone: gaps in touchscreen use matched wrist actigraphy (a movement
  wristband) closely for sleep onset and wake time (R² about 0.9). That is enough to choose "night"; it does not time
  falling asleep, which the headband does better.
- A 2026 paper built for exactly these four electrode sites reports 94.69 % for "focus", "relaxation", "engagement"
  and "flow", but its labels are lab tasks (imagined movement, eyes closed, real movement, eyes open) from lab
  recordings cut down to four channels; the authors write that it is not a measure of real-life states.
- Android lets an app start its recording in the background when the device is paired through Android's own
  companion pairing, or when the app may ignore battery optimisation; a tap on a notification is always allowed.
- People answer short one-tap questions well: in experience-sampling studies about 79 % of about 6 prompts a day were
  answered, and the number of prompts did not lower that.

## Where the data does not support it

- None of this has run on a phone yet. Whether the phone's system (Xiaomi's HyperOS) keeps the companion pairing's
  "headband near" working with the screen off is not documented anywhere.
- The contact limit for "on the head" (10 MΩ, at least half the electrodes) is a planning value until readings on and
  off the head are seen on the phone.
- The kind rules are guesses about one person's habits: working in bed late, an afternoon nap or a headband put on to
  test it will be guessed wrong. A wrong guess costs one quiet question, or one recording you delete.
- The battery numbers (10 % an hour, 15 % margin, 4 hours to charge) are planning values, not measured on this
  headband.
- The headband's own detectors (eyes closed, drowsy, asleep, jaw, movement) only confirm what happens inside a
  session; they are not used to decide whether to start.

## How the app uses this

- Settings, "When I put the headband on": Start automatically, Ask me (the default) or Do nothing, for the night, work
  and anything else ("anything else" can only ask or do nothing for now).
- Checks happen only at sensible moments: when you open the app, every 10 minutes in your bedtime window (from 2 hours
  before your usual bedtime to your usual wake-up, from your last 14 days of recorded nights; 23:00 to 07:00 until 3
  nights are recorded; you can set it by hand), when Android says the paired headband came near (at most every 30
  minutes), and when the laptop says a work session started (prepared; the laptop does not send it yet). Never during
  a recording or a session.
- A check connects for about 10 seconds: contact on every electrode, by name (any headband or helmet), and the
  battery, then it lets go. A board without contact readings would be judged from 20 seconds of signal instead (flat
  or railed means not on skin); the DIY helmet must never use its chip's lead-off currents on a person.
- The kind: the laptop's work session means work; inside the bedtime window, or charging with the screen off for 2
  minutes after 20:00, or Do Not Disturb on after 20:00, means night; anything else is "other".
- Ask me: one quiet notification ("Headband on. Start the night?", "... a work session?", or "What are you doing?").
  Meanwhile the minutes since the check are kept in memory, at most 15. Yes saves them as the night's first part, so
  the night counts from when you put the headband on; Not now, or no answer in 15 minutes, writes nothing and asks
  about that kind no more for 30 minutes and for the rest of that wearing.
- After 10 yes in a row for the night or work, the app offers to start it by itself; only your tap switches it.
- Start automatically only ever means recording and silent analysis: the night recorder with its drift-off detector
  and the sleep report after Stop, or a work session whose hints show on the screen (the chime only if you switched it
  on for automatic sessions). Never sounds, alarms, lucid or memory cues, neurofeedback, the dream catcher or the
  microphone.
- The night comes first: a daytime session starts only while the headband keeps enough for tonight (your usual night
  times 10 % an hour plus 15 %, or down to 15 % when bedtime is 4 hours or more away) and stops itself in time; else
  the app says "Charge the headband for tonight". A night is never refused, only warned about.
- Every check, guess, question, answer and outcome is kept on the phone (Export data takes it), so the settings page
  can say how often the guess was right, and a personal model can learn from your answers later.

## Sources

- [BrainBit device page](https://sdk.brainbit.com/device-brainbit/)
- [BrainBit battery complaint (GitLab issue 55)](https://gitlab.com/brainbit-inc/brainbit-sdk/-/issues/55)
- [Android: starting a foreground service from the background](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)
- [Android: foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [Android: CompanionDeviceManager](https://developer.android.com/reference/android/companion/CompanionDeviceManager)
- [Android: companion device pairing](https://developer.android.com/guide/topics/connectivity/companion-device-pairing)
- [Keeping an app alive on Xiaomi (kdroidfilter 2024)](https://kdroidfilter.github.io/blog/2024/prevent-app-from-being-killed-xiaomi)
- [Muse S Athena review (Wareable)](https://www.wareable.com/health-tech/muse-s-athena-review)
- [Neurable FAQ](https://www.neurable.com/faq)
- [Apple Watch automatic workout detection (MacRumors)](https://macrumors.com/how-to/use-automatic-workout-detection-watchos-5)
- [Fitbit automatic activity recognition (Google help)](https://support.google.com/fitbit/answer/14236510?hl=en)
- [Phone use and sleep timing (Borger 2019)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6662846/)
- [Cognitive states from a four-electrode headband, and its limits (Ngo et al. 2026)](https://orbi.uliege.be/bitstream/2268/345428/1/_Phong%20Ngo%20etal-2026-Toward%20Real-Time%20Cognitive%20State%20Sensing%20in%20Everyday%20Work-BME11.pdf)
- [Mixed-initiative interfaces: when to act, ask or wait (Horvitz 1999)](https://www.erichorvitz.com/chi99horvitz.pdf)
- [Guidelines for human-AI interaction (Amershi 2019)](https://www.microsoft.com/en-us/research/publication/guidelines-for-human-ai-interaction/)
- [How often people answer experience-sampling prompts (Wrzus and Neubauer 2022)](https://heibib.ub.uni-heidelberg.de/search/Record/1839595345)

## Libraries and models

- Android's CompanionDeviceManager (part of Android); no new library.
- The app's own contact check, night recorder and work session (this repository, MIT).

Checked: 2026-11-20
