# Real CallRec assets: use these, do not draw look-alikes

Everything shown of the app must look exactly like the real app. Use these files as-is.

## Images in this folder

- `app-icon.png` (1024x1024): the real app icon. Use it for the logo / end card.
- `menubar-icon.png`: the menu bar icon when idle (SF Symbol `waveform.circle`, rendered white on transparent; tint it black for a light menu bar).
- `menubar-icon-recording.png`: the icon while recording (`waveform.circle.fill`). This is the ONLY change while recording: no timer, no red dot in the menu bar.
- `menubar-icon-warning.png`: shown only when something is wrong (`exclamationmark.triangle.fill`). Don't use it in the ad.

## The menu (a native macOS menu, English text, exactly this order)

When ready (not recording):

```
Ready
─────────────
Start recording   ⌃⌥R
  Start automatically when a call starts      (toggle, off by default)
  Name recordings from Calendar               (toggle)
─────────────
Recent recordings
  Today 13:00 · Chrome · 90 min
  Today 11:01 · daily · 19 min
Show all recordings…                     ⌘O
─────────────
Test mic and system audio
  Open at login                               (toggle)
Quit CallRec                             ⌘Q
```

While recording, the first line becomes `Recording 12:34 · Zoom` (live timer, inside the menu only) and the button becomes `Stop recording   ⌃⌥R`.

Draw it as the standard macOS Sonoma/Sequoia menu: translucent rounded panel, SF Pro 13pt, grey section header ("Recent recordings"), checkmarks on the left, shortcuts right-aligned in grey.

The app UI is in English. Keep every UI string in English exactly as above, even though the ad's captions are Hebrew.

## The Recordings window

- Left sidebar: search field "Search transcripts", list rows with a bold title ("Today 13:00", or the meeting name if named) and a grey subtitle ("Chrome · 1 h 30 min · Hebrew").
- Top bar: play button, time, slider, total time, then buttons: copy, folder, pencil (rename), trash.
- Info card: Date, Duration, App, Language, Transcribed with, Microphone, Played through.
- Transcript (right-to-left for Hebrew): each line has the speaker in bold, "אני" in system blue, "הצד השני" in system orange, then a small timestamp link like `02:15`, then the text. A legend above: blue dot "אני your microphone", orange dot "הצד השני what your Mac played".
- Use generic sample dialogue (a project sync), never real call text.
