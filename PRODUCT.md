# Product

<!-- impeccable:product-schema 1 -->

Written by an assistant on 2026-11-18 while the owner was asleep (no way to ask). Every fact below comes
from the owner's brief, README.md and DECISIONS.md; lines marked *(inferred)* are assumptions to confirm.

## Platform

android

## Users

The owner first: one person who records his own sleep EEG with a BrainBit Black headband and a Xiaomi
phone (HyperOS, Android 14). Later, people who build the DIY ADS1299 helmet or buy an affordable headband
(project mission: affordable EEG for everyone, outside contributors expected).

The recorder screen is used at bedtime and on waking: lights off or dim, the user lying down, tired,
glancing at the phone for a few seconds, possibly half-asleep at 3 a.m. after a disconnect. *(inferred
from "readable half-asleep at night")*

## Product Purpose

Record a full night of raw EEG on the phone with one tap ("put the headband on, tap one button, sleep"),
and lose seconds, not the night, when Bluetooth or the phone's battery management interferes. Heavy
analysis (sleep staging) happens later on a PC.

## Positioning

Open (MIT) and honest: the raw signal is kept in documented files the user owns; nothing claims more than
the data supports (no unvalidated stress or focus scores, sleep stages labelled unvalidated).

## Operating Context

- Start: headband on, open the app, Start night, glance at contact quality, put the phone down.
- During the night: the screen is normally off; a foreground notification shows the recorder is alive.
- Morning: Stop, then "Export a night" copies the night out of the app's private folder into a folder the
  user picks (e.g. Download/EEG or a Syncthing folder); from there `adb pull`, USB or Syncthing take it to the PC.
- Xiaomi phones kill background work by default; the user must fix several phone settings once.

## Capabilities and Constraints

- BrainBit Black: 4 channels (O1 O2 T3 T4), 250 Hz, contact resistance check, battery level.
- Signal strength is known only from the scan before connecting (the SDK gives no live value).
- Contact thresholds (good / fair / poor) are planning assumptions until calibrated on real nights.
- Not a medical device.

## Evidence on Hand

No real phone screenshots, recordings from the phone, or user feedback yet. Nothing may be shown as
measured that was not measured.

## Product Principles

1. The night is the product: never lose recorded data, and say plainly when recording is not happening.
2. One tap to start; everything else is glanceable.
3. Calm at night: nothing bright, loud or blinking that would wake the user. *(inferred)*
4. Honest numbers: show what was measured, with units, and label assumptions.

## Accessibility & Inclusion

Must be readable by a tired eye in the dark without glasses at arm's length *(inferred)*; follows the
system font size; touch targets at least 48 dp.
