// "Try these" (DECISIONS 340): each feature's first try as a short card, in the order to try them. Written by hand
// from the "Owner step" sections of app/README.md, in plainer words; `test/try_these_test.dart` fails when the README
// gains an owner step with no card here. Pure data: no files, no Flutter.

/// When in the owner's week a card belongs, in page order.
enum TryGroup { tonight, anotherNight, sessions, weeks, charged, board }

const Map<TryGroup, String> tryGroupTitles = {
  TryGroup.tonight: 'Tonight, then the morning',
  TryGroup.anotherNight: 'Another night',
  TryGroup.sessions: 'Sessions, when you have time',
  TryGroup.weeks: 'Over the next weeks',
  TryGroup.charged: 'When the headband is charged',
  TryGroup.board: 'When the board is built',
};

/// The screen a card's button opens. [nightScreen] goes back to the main screen (Start night, Your data).
enum TryOpen {
  nightScreen,
  sleepReport,
  alarm,
  morning,
  trends,
  export,
  meditation,
  alphaTheta,
  training,
  dream,
  lucid,
  nap,
  sound,
  work,
  settings,
  experiments,
  sharpHours,
  study,
  ownBle,
}

/// The button's words for each screen.
const Map<TryOpen, String> tryOpenLabels = {
  TryOpen.nightScreen: 'Back to the main screen',
  TryOpen.sleepReport: 'Open Sleep report',
  TryOpen.alarm: 'Set alarm',
  TryOpen.morning: 'Open Morning check-in',
  TryOpen.trends: 'Open Trends',
  TryOpen.export: 'Open Export data',
  TryOpen.meditation: 'Open Meditation',
  TryOpen.alphaTheta: 'Open Alpha-theta',
  TryOpen.training: 'Open Training settings',
  TryOpen.dream: 'Open Dream catcher',
  TryOpen.lucid: 'Open Lucid dreams',
  TryOpen.nap: 'Open Nap coach',
  TryOpen.sound: 'Open Sound',
  TryOpen.work: 'Open Work session',
  TryOpen.settings: 'Open Settings',
  TryOpen.experiments: 'Open Experiments',
  TryOpen.sharpHours: 'Open Sharp hours',
  TryOpen.study: 'Open Study reminders',
  TryOpen.ownBle: 'Open Headband connection',
};

/// Where a card comes from in app/README.md: a `## ` section (its title without the part in brackets) and, when it
/// has one, the title of its `### Owner step:` heading (also without the brackets).
class TryRef {
  const TryRef(this.section, [this.step]);
  final String section;
  final String? step;
}

class TryCard {
  const TryCard({
    required this.id,
    required this.group,
    required this.title,
    required this.what,
    required this.takes,
    required this.steps,
    required this.tell,
    required this.opens,
    required this.readme,
    this.evidence,
    this.weakEvidence = false,
    this.proposal = false,
    this.auto = false,
  });

  /// Stable: the progress file and the export key on it.
  final String id;
  final TryGroup group;
  final String title;

  /// What it is, in one sentence.
  final String what;

  /// How long it takes ("About 15 minutes, one morning").
  final String takes;
  final List<String> steps;

  /// What to tell the assistant afterwards.
  final List<String> tell;
  final TryOpen opens;
  final List<TryRef> readme;

  /// The evidence note (`docs/evidence/NAME.md`, the "i" on the feature's screen) this card's feature is graded by;
  /// null when it has none.
  final String? evidence;

  /// The note's grade is "weak": the page says so beside the card (`test/try_these_test.dart` checks the flag
  /// against the note's own grade line).
  final bool weakEvidence;

  /// The assistant's proposal, not one of the owner's wishes.
  final bool proposal;

  /// The app ticks it by itself when it sees it done (lib/try_these/seen.dart).
  final bool auto;
}

const List<TryCard> tryCards = [
  TryCard(
    id: 'night',
    group: TryGroup.tonight,
    title: 'A night with Lights off',
    what: 'Record the night as usual and tap Lights off as you close your eyes, so the app can tell when you fell asleep.',
    takes: 'A few seconds tonight, 2 minutes in the morning',
    steps: [
      'Headband on and switched on. Tap Start night.',
      'Lie down. When you close your eyes to sleep, tap Lights off (bottom left).',
      'Got up in the night? Tap Lights off again when you lie back down.',
      'In the morning tap Stop. Once the night is scored, open Sleep report and scroll to Falling asleep.',
      'Do the same for the next four nights: then the app knows whether its guess can be trusted.',
    ],
    tell: [
      'Did the line above the buttons say "Learning your eyes-closed alpha" after Lights off?',
      'The two numbers under Falling asleep, and whether they feel right.',
      'Anything odd in the night: the app closed, the headband dropped out.',
    ],
    opens: TryOpen.nightScreen,
    readme: [TryRef('Lights off and falling asleep', 'tonight and the next four nights')],
    evidence: 'sleep-recording',
    auto: true,
  ),
  TryCard(
    id: 'sleep-time',
    group: TryGroup.tonight,
    title: 'How long the phone takes to score a night',
    what:
        'After Stop the phone works out your sleep stages itself; nobody knows yet how long that takes on your phone.',
    takes: 'About 15 minutes, one morning (mostly waiting)',
    steps: [
      'In the morning tap Stop and leave the app open. Note the time, and whether the phone is on the charger.',
      'The Sleep section says what it is doing ("Sleep model, run 1 of 3, part 1 of 26" and so on).',
      'When the time asleep shows, note the time again.',
      'Open Sleep report: the bottom line says "Scored on this phone in ...".',
      'If it says scoring stopped, tap Try again once.',
    ],
    tell: [
      'Hours recorded, and how long scoring took.',
      'Did the phone get warm, or did the app close?',
      'What happened after Try again, if you needed it.',
    ],
    opens: TryOpen.sleepReport,
    readme: [TryRef('Sleep report', 'how long does the phone take?')],
    evidence: 'sleep-scoring',
    auto: true,
  ),
  TryCard(
    id: 'sleep-extras',
    group: TryGroup.tonight,
    title: 'Sleep report: noise, jaw and movement',
    what: 'The report also shows where the signal was noisy and counts jaw-muscle bursts and movements.',
    takes: '2 minutes, a morning',
    steps: [
      'Open Sleep report once the night is scored.',
      'Under the totals: how much of your sleep was read through noise.',
      'Under the chart, the Signal line: do the amber parts match when you turned over or touched the headband?',
      'Scroll to Jaw and movement, and to Hour by hour.',
    ],
    tell: [
      'The jaw and movement numbers (an hour asleep), and the noise share.',
      'Anything that looks wrong in Hour by hour, for example an hour you were awake and talking with no jaw bursts.',
    ],
    opens: TryOpen.sleepReport,
    readme: [TryRef('Sleep report', 'the night extras')],
    evidence: 'jaw-and-blinks',
  ),
  TryCard(
    id: 'check-in',
    group: TryGroup.tonight,
    title: 'Morning check-in and Trends',
    what:
        'Six minutes after waking: eyes closed, eyes open, a few questions; the phone works out your morning numbers.',
    takes: 'About 10 minutes, a morning',
    steps: [
      'Stop the night first. Headband on, sound on, sit comfortably.',
      'Morning check-in, then Check contact. The back two (O1, O2) matter most: part the hair, press, check again.',
      'Follow the tones: eyes closed 2 minutes, then look at the dot 2 minutes. Answer the questions and Save.',
      'Open Trends: last night\'s sleep and this morning\'s numbers should be there.',
    ],
    tell: [
      'Did the tones play, and were they soft enough? Did the screen dim with your eyes closed?',
      'Did the contact words match? Lift O1 for a moment: it should say "not touching" or "noisy".',
      'Your alpha speed (the laptop measured about 9.6 Hz).',
      'What felt wrong or slow, and at which step, if the app stalled.',
    ],
    opens: TryOpen.morning,
    readme: [TryRef('Trends', 'the first phone check-ins')],
    evidence: 'morning-check-in',
    auto: true,
  ),
  TryCard(
    id: 'export',
    group: TryGroup.tonight,
    title: 'Export data to the laptop',
    what: 'Everything the app keeps stays on the phone until you export it: set the folder once, then export every few days.',
    takes: '5 minutes once, then a minute every few days',
    steps: [
      'Open Export data and tap Pick a folder: Syncthing\'s folder, or make a folder EEG in Download.',
      'Tap Use this folder and Allow. The app remembers it.',
      'Tap Export new and keep the app open until it says Exported.',
      'Get the folder eeg-export to the laptop (Syncthing, or the USB cable) and tell the assistant.',
    ],
    tell: ['How long the first export took.', 'Anything the laptop\'s import called a PROBLEM.'],
    opens: TryOpen.export,
    readme: [TryRef('Export data', 'set it up once, then export every few days')],
    auto: true,
  ),
  TryCard(
    id: 'smart-alarm',
    group: TryGroup.anotherNight,
    title: 'Smart alarm',
    what:
        'Wakes you in a window you choose at a light moment, never in deep sleep, and always by the end of the window.',
    takes: '2 minutes before a night',
    steps: [
      'Once, in the phone\'s settings for EEG Tracker: allow Show on lock screen and pop-up windows in the background.',
      'Set the phone\'s alarm volume (not media) to where an alarm wakes you.',
      'Before the night: Set alarm (above Start night), your usual time, 30 min. Then Start night.',
      'Check that the alarm icon shows at the top of the screen.',
    ],
    tell: [
      'Did it wake you, at what time, and did you feel groggy?',
      'Was the first note too soft or too loud?',
      'Did I\'m awake show over the lock screen, or only in the notification?',
      'The Waking up lines in the Sleep report.',
    ],
    opens: TryOpen.alarm,
    readme: [TryRef('Smart alarm', 'the first smart alarm')],
    evidence: 'smart-alarm',
    weakEvidence: true,
    auto: true,
  ),
  TryCard(
    id: 'share',
    group: TryGroup.anotherNight,
    title: 'Share on Wi-Fi',
    what: 'The laptop copies the night while the phone records, and can show your live signal.',
    takes: '2 minutes before a night, with the laptop on',
    steps: [
      'Phone and laptop on your home Wi-Fi. On the main screen, Your data: switch Share on Wi-Fi on.',
      'The sheet shows the address, the code and two laptop commands: start them on the laptop, or ask the assistant.',
      'Start the night as usual and sleep.',
      'In the morning tap Stop and leave the app open for a few minutes.',
    ],
    tell: [
      'Did the laptop keep getting data all night with the screen off, or say "no answer" for long stretches?',
      'Was the phone on the charger?',
    ],
    opens: TryOpen.nightScreen,
    readme: [TryRef('Share on Wi-Fi', 'switch it on before a night')],
  ),
  TryCard(
    id: 'work',
    group: TryGroup.sessions,
    title: 'Work session',
    what: 'Wear the headband while you work; the phone watches for heavy eyelids and suggests a break now and then.',
    takes: '2 minutes to start, then a working day',
    steps: [
      'Between nights, headband on, when you feel fresh. Open Work session, tap Start work session.',
      'Work as usual for the first 4 minutes (your baseline). Then lock the phone if you like.',
      'When the soft chime comes, look: Snooze, Not now, or On a break. Tap how sharp you feel if you can.',
      'Tap On a break when you get up, and Back when you return. Stop at the end of the day.',
    ],
    tell: [
      'Did "getting drowsy" or "drowsy" come when you felt heavy-eyed, and stay away when you felt fine?',
      'Were the hints too many, too few, or about right? Was the chime soft enough?',
      'Did the session keep going with the phone locked, and how much battery did the phone and the headband use?',
      'Was the headband comfortable for hours?',
    ],
    opens: TryOpen.work,
    readme: [TryRef('Work session', 'wear it while you work')],
    evidence: 'work-session',
    auto: true,
  ),
  TryCard(
    id: 'meditation',
    group: TryGroup.sessions,
    title: 'Meditation',
    what: 'Eyes closed for 5 to 20 minutes while rain and a drone follow your alpha rhythm, and a bell rings when you settle.',
    takes: 'About 15 minutes',
    steps: [
      'Between nights, headband on. Wired headphones or the phone\'s speaker (Bluetooth headphones are late).',
      'Open Meditation, pick 10 minutes, tap Start meditation.',
      'Calibration, 1½ minutes: look at the green dot, then close your eyes at the low tone.',
      'Then just listen. A third tone ends it; read the report.',
    ],
    tell: [
      'Did the sound start and feel right: the levels, the rain, the bells?',
      'Did it follow your eyes closing within about a second?',
      'Did a jaw clench show as restless? Does the report seem believable?',
    ],
    opens: TryOpen.meditation,
    readme: [TryRef('Meditate')],
    evidence: 'meditation-feedback',
    weakEvidence: true,
    auto: true,
  ),
  TryCard(
    id: 'sound',
    group: TryGroup.sessions,
    title: 'Sound for states',
    what: 'Calm sound to fall asleep, relax, focus, take a break or wake up; with the headband it shows what your brain did.',
    takes: '15 minutes, then one bedtime',
    steps: [
      'Open Sound. Tap Listen on each sound at a low volume, then add each beat and Listen again.',
      'Relax, Ocean, Measure, 5 minutes, headband on, eyes closed. Read the result.',
      'At bedtime: Fall asleep, Pink noise, Measure, Record the night. Sleep.',
    ],
    tell: [
      'Which sounds and beats you liked or disliked, and any level that was off.',
      'Does No beat sound as loud as with a beat?',
      'In the morning: did the sound stop by itself, and did the night record from then?',
      'Did "probably asleep N min after lights off" match how you felt?',
    ],
    opens: TryOpen.sound,
    readme: [TryRef('Sound for states', 'the first sound sessions')],
    evidence: 'sound-for-states',
    weakEvidence: true,
    auto: true,
  ),
  TryCard(
    id: 'locked',
    group: TryGroup.sessions,
    title: 'Lock the phone during a session',
    what: 'Sessions now go on with the phone locked, with Stop on the lock screen.',
    takes: '15 minutes, then one bedtime',
    steps: [
      'Open Sound: Relax, Ocean, Measure, 10 minutes, headband on. Tap Start.',
      'When the sound plays, press the power button and put the phone down.',
      'After about 5 minutes, wake the screen without unlocking: is there a card with Relax and Stop?',
      'At bedtime, note the battery. Fall asleep, Measure, Record the night, Screen: Can lock. Start, lock, sleep.',
    ],
    tell: [
      'Did the sound play all 10 minutes, without gaps or an early stop?',
      'Does the result cover the whole time (not "No signal")?',
      'Did Stop on the lock screen work?',
      'The battery at lights off and in the morning.',
    ],
    opens: TryOpen.sound,
    readme: [TryRef('Sessions with the phone locked', 'lock the phone during a session')],
  ),
  TryCard(
    id: 'nap',
    group: TryGroup.sessions,
    title: 'Nap coach',
    what: 'A nap that ends before deep sleep starts, or at the length you pick, with a soft rising sound.',
    takes: 'About 30 minutes, an afternoon',
    steps: [
      'No night recording. Open Nap coach and pick 30 min.',
      'Set the phone\'s media volume to where you would hear an alarm.',
      'Headband on, lie on your side, tap Lights off and nap.',
      'Tap I\'m awake when the notes play, then read the report.',
    ],
    tell: [
      'The report\'s Sleep model line (for example "3 runs, 2.1 s a check").',
      'Did the sound wake you? Was its first note too soft or too loud?',
      'Did it wake you before deep sleep or at 30 minutes, and were you groggy?',
      'Did the dim screen or the headband bother you lying down?',
    ],
    opens: TryOpen.nap,
    readme: [TryRef('Nap coach', 'the first nap')],
    evidence: 'nap-coach',
    auto: true,
  ),
  TryCard(
    id: 'dream',
    group: TryGroup.sessions,
    title: 'Dream catcher',
    what: 'As you drift off, the app asks what is on your mind and records your answer, 3 or 4 times; for ideas.',
    takes: '20 to 45 minutes, a nap or bedtime',
    steps: [
      'No night recording. Open Dream catcher: record your two prompts, play them, set the volume.',
      'Pick 3 rounds and Wake me.',
      'Headband on, lie down, tap Lights off, eyes closed. Answer aloud when it asks.',
      'Let it run to the wake tone, or tap Stop after the first answer.',
    ],
    tell: [
      'Did the questions come half asleep, too early or too late?',
      'Were the prompts too loud, too quiet, or fine?',
      'Was an answer cut off, or did it keep recording long after you stopped?',
      'Could you tap Drifting or Awake half asleep?',
    ],
    opens: TryOpen.dream,
    readme: [TryRef('Dream catcher', 'the first try')],
    evidence: 'dream-catcher',
    auto: true,
  ),
  TryCard(
    id: 'dream-words',
    group: TryGroup.sessions,
    title: 'Dream answers as words',
    what: 'The phone writes out your spoken answers as text, in Russian or English; they never leave the phone.',
    takes: 'About 10 minutes on Wi-Fi, once',
    steps: [
      'On Wi-Fi, open Dream catcher, scroll to Answers as text and tap Download (671 MB).',
      'Keep the page open until it says "Speech model on this phone".',
      'After the next session, watch the words appear under each answer.',
      'Fix a wrong word in its box.',
    ],
    tell: [
      'How long one answer took to write out, and whether the phone got warm.',
      'How close the words were, in Russian and in English.',
      'Did a mumble come out as "No words heard."?',
      'Did your fixes stay after you closed and opened the page?',
    ],
    opens: TryOpen.dream,
    readme: [TryRef('Dream catcher', 'answers as words')],
    evidence: 'dream-catcher',
    auto: true,
  ),
  TryCard(
    id: 'alpha-theta',
    group: TryGroup.sessions,
    title: 'Alpha-theta training',
    what: 'An eyes-closed drift toward the edge of sleep with a stream and ocean waves; practice, not treatment.',
    takes: 'About 30 minutes',
    steps: [
      'Open Alpha-theta. The first time: the screening questions and your stop plan.',
      'Check in, then Start the session: recline, wired headphones, eyes closed, 15 minutes.',
      'It can bring up strong memories or feelings: Stop is always there.',
      'Afterwards: a minute of grounding, the questions, and the reaction test before you drive.',
    ],
    tell: [
      'Were the stream and the waves pleasant at the same volume? The chime and the gong soft enough?',
      'Did a short doze fade the sound and wake you gently?',
      'Did the reaction test feel fair?',
    ],
    opens: TryOpen.alphaTheta,
    readme: [TryRef('Alpha-theta')],
    evidence: 'alpha-theta',
    weakEvidence: true,
    auto: true,
  ),
  TryCard(
    id: 'hands-free',
    group: TryGroup.sessions,
    title: 'Hands-free controls',
    what: 'A double jaw clench, or a look left then right, works as a switch during sessions.',
    takes: 'About 10 minutes, once',
    steps: [
      'Between nights: Settings (the gear on the main screen), switch Hands-free controls on.',
      'Calibrate sitting up: on each low tone clench twice; on each rising tone look far left, then far right.',
      'Then a 10-minute Sound session (Relax). Clench twice: does the sound pause? Again: does it come back?',
      'Look left, then right: one higher note?',
    ],
    tell: [
      'The result page: Works or Not used for each gesture, and the numbers after each try.',
      'How many tries each gesture took in the session.',
      'Did anything happen when you did nothing?',
    ],
    opens: TryOpen.settings,
    readme: [TryRef('Hands-free controls', 'calibrate and try it')],
    evidence: 'hands-free',
  ),
  TryCard(
    id: 'lucid',
    group: TryGroup.weeks,
    title: 'Lucid dream cues',
    what: 'Soft rising tones in dream sleep, after an evening practice, to help you notice you are dreaming.',
    takes: '15 minutes an evening, 1 minute a morning',
    steps: [
      'In the evening open Lucid dreams, tap Turn on and do the practice to the end.',
      'Then Start night and Lights off as usual.',
      'Once, awake with the headband on, make the eye signal on purpose (left-right-left-right, twice, wide, eyes closed) and note the time.',
      'Next morning answer the three questions before anything else.',
    ],
    tell: [
      'Did you hear the practice\'s first cues at the level you tapped? Did the night wake you?',
      'The night\'s .log end line "lucid cues: ... s of the recorder\'s time", and any line starting "lucid cues stopped" or "lucid cues off".',
      'The phone\'s battery drain that night, against a night without the cues.',
      'The times of your eye signals. Then Export data after a few nights.',
    ],
    opens: TryOpen.lucid,
    readme: [TryRef('Lucid dream cues', 'the first week')],
    evidence: 'lucid-cues',
    weakEvidence: true,
    auto: true,
  ),
  TryCard(
    id: 'experiment',
    group: TryGroup.weeks,
    title: 'A first self-experiment',
    what: 'The app picks random days to skip late caffeine, and after 4 weeks says what that did to your sleep.',
    takes: '2 minutes, then one tap a day for 4 weeks',
    steps: [
      'Open Experiments and tap New experiment.',
      'Choose "No caffeine in the last 8 hours before bed", keep Asleep and 4 weeks, tap Start tomorrow.',
      'Each day look at the task once; wear the headband at night and do the check-in.',
      'Tap Kept or Not kept for the day before.',
    ],
    tell: [
      'Was the task easy to find?',
      'Did the day change at a sensible hour for you (a day runs 04:00 to 04:00)?',
      'Anything unclear in the words.',
    ],
    opens: TryOpen.experiments,
    readme: [TryRef('Self-experiments', 'start a first experiment')],
    evidence: 'self-experiments',
    auto: true,
  ),
  TryCard(
    id: 'replay',
    group: TryGroup.weeks,
    title: 'Replay check',
    what: 'Finds out whether the live link to your brain matters: some sessions quietly replay an earlier session\'s sound.',
    takes: 'A switch, then 24 to 36 sessions',
    steps: [
      'Open Training settings and switch Replay check on.',
      'Meditate as usual. The first 4 sessions are always live.',
      'After each check session, answer the short questions with your honest guess.',
      'Please do not test it, for example by opening your eyes to see whether the rain reacts.',
    ],
    tell: [
      'Were the questions after a session clear?',
      'After 12 sessions, open See the results together with the assistant.',
    ],
    opens: TryOpen.training,
    readme: [TryRef('Replay check')],
    evidence: 'replay-check',
    auto: true,
  ),
  TryCard(
    id: 'sharp',
    group: TryGroup.weeks,
    title: 'Sharp hours',
    what: 'A few one-tap questions a day, "How sharp do you feel?", to learn when in the day you are sharpest.',
    takes: '2 minutes, then a few taps a day',
    steps: [
      'Open Sharp hours, switch it on and allow notifications. Check the waking hours.',
      'On the Xiaomi: Autostart on, and Battery saver: No restrictions for EEG Tracker.',
      'Answer what comes for two days.',
      'Then open the page again: it says how many questions reached you.',
    ],
    tell: [
      'Did a question come at a bad moment (asleep, in a session)?',
      'Was the sound too much? Was the reaction test too long to do twice a day?',
      'If it says "Only N of M questions reached you": the two numbers.',
    ],
    opens: TryOpen.sharpHours,
    readme: [TryRef('Sharp hours', 'switch it on and watch the first two days')],
    evidence: 'sharp-hours',
    proposal: true,
    auto: true,
  ),
  TryCard(
    id: 'study',
    group: TryGroup.weeks,
    title: 'Study reminders',
    what: 'A nudge to study in the evening and to try recalling it the next morning, with one tap to say how it went.',
    takes: '2 minutes, then a tap twice a day',
    steps: [
      'Open Settings, then Study reminders. Switch it on and allow notifications. Look at the two times.',
      'On the Xiaomi: Autostart on, and Battery saver: No restrictions for EEG Tracker.',
      'In the evening: study something for a while, then tap the reminder and answer.',
      'Next morning: try to recall it before looking, then tap the reminder and answer.',
    ],
    tell: [
      'Did a reminder come at a bad moment (asleep, in a session)?',
      'Was the evening time too close to bed, or too early? Did the morning one come before you were up?',
      'How many reminders arrived in the last 7 days, as the page says?',
    ],
    opens: TryOpen.study,
    readme: [TryRef('Study reminders', 'switch it on and watch the first two days')],
    evidence: 'study-timing',
    proposal: true,
    auto: true,
  ),
  TryCard(
    id: 'unusual',
    group: TryGroup.weeks,
    title: 'Unusual for you',
    what:
        'After 4 weeks of nights and check-ins, one calm line when a number has been unusual for you 2 days in a row.',
    takes: 'Nothing for 4 weeks, then 1 minute',
    steps: [
      'Record nights and do the check-in as usual.',
      'Now and then open Trends: under Unusual for you the count climbs ("5 of 28 days").',
      'When a card appears, read it and tap what might explain it, or nothing.',
      'If it worries you more than it helps, switch it off beside its heading.',
    ],
    tell: ['Did the card match how you felt?', 'Were the words calm enough?'],
    opens: TryOpen.trends,
    readme: [TryRef('Unusual for you', 'nothing to do for 4 weeks, then one look')],
    evidence: 'unusual-for-you',
    proposal: true,
  ),
  TryCard(
    id: 'was-this-you',
    group: TryGroup.weeks,
    title: 'Was this you?',
    what: 'After about two weeks of check-ins and Lights off nights, it asks when a recording looks unlike your usual.',
    takes: 'Nothing for about two weeks, then 1 minute',
    steps: [
      'Do the check-in and tap Lights off at night as usual: the count at the end of each result climbs ("4 of 10").',
      'If anyone else wears the headband, tap Someone else wore it on that recording.',
      'If it asks about a recording that was you, tap Yes, it was me.',
      'If it asks too often, switch it off in Settings.',
    ],
    tell: [
      'If it asked about you: what was different that day (alcohol, a short night, the headband sat differently)?',
      'Did it ask too often?',
    ],
    opens: TryOpen.settings,
    readme: [TryRef('Was this you?', 'nothing to do for about two weeks, then one look')],
    evidence: 'was-this-you',
    weakEvidence: true,
    proposal: true,
  ),
  TryCard(
    id: 'own-ble',
    group: TryGroup.charged,
    title: 'Our own headband connection',
    what: 'Our own Bluetooth code instead of BrainBit\'s mends short drops inside the same recording; first a 5-minute probe.',
    takes: '15 minutes, then one night',
    steps: [
      'Charge the headband. Stop any night; media volume about half.',
      'Open Headband connection, tap Run the probe. Headband on, tap Ready, follow the page.',
      'Passed: switch on Use our own connection (test) and record a night. Once, walk out of range for a minute.',
      'Anything else: do not switch. Export data and tell the assistant.',
      'If the night goes wrong, switch it off again: nothing else changes.',
    ],
    tell: [
      'The sentence on top of the probe\'s result.',
      'In the morning: was the sleep report there as usual? Did Recording come back by itself after the walk?',
      'Then Export data, so the assistant can read the night\'s log.',
    ],
    opens: TryOpen.ownBle,
    readme: [TryRef('Our own headband connection', 'the probe on the phone, then one night with the switch on')],
    proposal: true,
  ),
  TryCard(
    id: 'diy-board',
    group: TryGroup.board,
    title: 'The DIY board on the phone (test, not EEG yet)',
    what: 'Once the board passes its bench steps, the phone records its test signal over Wi-Fi: a test, not EEG yet.',
    takes: '15 minutes, once',
    steps: [
      'Only after the bring-up card\'s bench steps pass. In the firmware: Wi-Fi on, your Wi-Fi, and the phone\'s address.',
      'Open Headband connection, choose DIY board (test). Answer the board\'s prompts on the laptop: R, V, then T.',
      'Tap Start night. Within a minute: "not EEG" and about 3750 µV on every channel.',
      'After 10 minutes: Stop, then Export data.',
      'Choose BrainBit again before any BrainBit night or session.',
    ],
    tell: [
      'Did every channel read about 3750 µV?',
      'How many samples did it say were lost?',
      'Then import the export on the laptop, so the assistant can read the board\'s log.',
    ],
    opens: TryOpen.ownBle,
    readme: [TryRef('The DIY board', 'the board on the phone')],
    auto: true,
  ),
];
