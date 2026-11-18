# Sleep recording

## What it does

Records the headband's four channels all night to a file (on the laptop now, on the phone soon), keeps going
through Bluetooth drops, and shows a live check of each electrode's contact and noise.

## Evidence for this headband: some

The data stream is tiny and the back electrodes match lab electrodes well, but nobody has published how often a
dry headband like this keeps good contact through a whole night at home.

## What the research says

- A dry headband with exactly this electrode layout matched lab gel electrodes for the alpha rhythm (the
  8-12 Hz wave at the back of the head that grows when you close your eyes): correlation 0.90 in 19 adults.
- The headband sends only about 3,000 bytes a second, so a phone or laptop keeps up easily. An 8-hour night is
  about 90 MB as a BDF+ file (a standard EEG file format), about 33 GB a year.
- Dry headbands lose some nights at home: about 10% of dry home nights failed in one study, and a Muse-S study
  lost 16% of nights to poor signal.
- Bluetooth drops come from a weak radio path (distance, your body, a pillow), not from a slow link. Keep the
  phone within about 1 m, in line of sight, not under the pillow.
- Brain recordings identify a person like a fingerprint: two channels of home sleep EEG re-identified 86% of
  35 people. That is why recordings stay on your own devices.

## Where the data does not support it

- No study has tested whether this headband is comfortable and keeps contact while you lie on it. Whether it
  does decides whether the night features work at all.
- No gap-free night is promised yet: the phone app's all-night test has not been run, and some phone makers
  (Xiaomi among the strictest) stop apps running in the background.
- The headband's battery reading sticks at 0-2% or 100% while streaming, and makers' figures differ (10 to 15
  hours), so "hours left" is an estimate from the trend.
- The headband's own packet counter sometimes repeats numbers. That is a known bug in the vendor's software;
  the app can count it but not fix it.

## How the app uses this

- One program, the recorder, holds the headband's single Bluetooth link, writes every sample to disk and shares a
  live stream with any page or tool. A page closing never stops the recording.
- After 40 s without data the laptop recorder starts a fresh process and a new file. In the morning the night's
  files are joined into one BDF+ file; missing time is marked as a gap, never filled with made-up values.
- The live check page shows, per electrode: contact, noise, mains hum and a moving trace, plus an eyes-closed
  alpha test for the back pair.
- Battery: stuck readings are ignored and a line through the last 90 minutes gives "about N h left".
- Phone app (in progress): one background service of Android's "connected device" type, which has no time
  limit, reconnecting straight to the saved headband instead of scanning for it.
- Nothing is uploaded. There is no account and no server.

## Sources

- [Mikhaylov 2024: dry headband vs gel, same layout](https://pmc.ncbi.nlm.nih.gov/articles/PMC11679099/)
- [ZMax home nights (about 10% failed)](https://www.medrxiv.org/content/10.64898/2026.06.01.26354591v1)
- [Muse-S sleep study (Lanthier 2026)](https://espace2.etsmtl.ca/33349/1/Lina-JM-2026-33349.pdf)
- [Bluetooth range](https://www.bluetooth.com/learn-about-bluetooth/key-attributes/range/)
- [Two-channel sleep EEG re-identification](https://arxiv.org/html/2509.20454)
- [dontkillmyapp: Xiaomi](https://dontkillmyapp.com/xiaomi)
- [BrainBit SDK device page (battery up to 10 h)](https://sdk.brainbit.com/device-brainbit/)
- [BrainBit issue 45: packet numbers repeat](https://gitlab.com/brainbit-inc/brainbit-sdk/-/issues/45)
- [Android foreground service types](https://developer.android.com/develop/background-work/services/fgs/service-types)
- [BioSemi BDF format FAQ](https://biosemi.com/faq/file_format.htm)

## Libraries and models

- [neurosdk2](https://pub.dev/packages/neurosdk2) (MIT wrapper around BrainBit's closed core library): the
  headband connection in the phone app.
- [pyneurosdk2](https://pypi.org/project/pyneurosdk2/) (MIT wrapper, same closed core): the headband connection
  on the laptop.
- [pyedflib](https://github.com/holgern/pyedflib/blob/master/LICENSE) (BSD-3): writes the night's BDF+ file.
- [flutter_foreground_task](https://pub.dev/packages/flutter_foreground_task) (MIT): keeps the phone app
  recording with the screen off.

Checked: 2026-11-18
