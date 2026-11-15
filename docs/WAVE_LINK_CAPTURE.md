# Recording a real Wave Link session

The Wave Link tests in Waves run against a fake Wave Link. Some of its
behavior is a guess, most importantly how quickly Wave Link reports a new
channel level after Waves sets it. One recording from a real Mac running
Wave Link 3 turns those guesses into facts. It takes about five minutes.

## What you need

- The Mac with Wave Link 3 and your Elgato hardware.
- Waves 1.8.0 or later, installed and running, with Wave Link compatibility on
  and Waves chosen as the per-app controller (Settings › Mixer).
- One app with its own Wave Link software channel, playing sound. A browser
  playing a video works well.
- Two Terminal windows, both opened in a copy of the Waves source.

## Record

1. In the first Terminal window, start the Waves log. It shows each change
   Waves sends and every read-back it makes:

   ```sh
   log stream --level debug --style compact \
     --predicate 'subsystem == "com.jonathanreed.Waves" AND category == "WaveLinkBridge"' \
     > ~/Desktop/waves-wavelink-log.txt
   ```

2. In the second window, start the recorder. It reads Wave Link's channel list
   20 times a second for 90 seconds and never changes anything in Wave Link:

   ```sh
   swift script/wave-link-capture.swift
   ```

   It prints where it writes, by default
   `~/Desktop/wave-link-capture-<date>-<time>.jsonl`. Use `--seconds 180` for
   more time.

3. While it records, do these in Waves, on the app's row. Wait about two
   seconds between steps so they are easy to tell apart:
   1. Move the volume by a small step, for example 50% to 45%.
   2. Make one big jump: drag from 100% to 10% and let go.
   3. Make the opposite jump: 10% to 100%.
   4. Make a fast drag: sweep the slider quickly back and forth a few times and
      let go somewhere in the middle.
   5. Mute the app, wait, and unmute it.
   6. Mute the app while you drag the slider, then unmute it.

4. When the recorder prints `Done`, stop the log with Control-C in the first
   window.

## Send back

- `wave-link-capture-<date>-<time>.jsonl` from the Desktop.
- `waves-wavelink-log.txt` from the Desktop.
- Your Wave Link version (Wave Link › About).
- A note of anything that looked wrong, with the step number.

The files contain channel names, app bundle identifiers, levels, and mute
states. They contain no audio.

## What the files answer

- Whether a large level step shows up in Wave Link's channel list at once, a
  little later, or in several steps (a fade), and how long that takes. Waves
  waits up to 600 ms for it.
- Whether Wave Link reports levels as whole percents.
- Whether Wave Link pushes its own messages when a level changes. Each line
  of the capture with `"direction":"in"` and no `id` is one of those.
