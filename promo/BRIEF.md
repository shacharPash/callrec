# Brief: a 25-second promo video for CallRec

Work ONLY inside this folder (`~/callrec/promo`). Do not touch anything else in `~/callrec`, do not publish, upload or push anything.

## What CallRec is (facts, don't invent features)

A free macOS menu bar app (made by a friend, shared with friends) that records calls and transcribes them locally.

- Click the waveform icon in the menu bar > "Start recording", or press Ctrl+Option+R from anywhere. Stop the same way. It also stops by itself after the call ends.
- Records both sides: your mic, and what the Mac plays (the other side). Works in any app: Zoom, Google Meet, Slack huddles, Teams, WhatsApp, FaceTime. With or without headphones, even if you switch headphones mid-call.
- No bot joins the meeting and nothing shows to the other participants. Discreet: the menu bar icon only fills in, no timer, no pop-ups (safe for screen sharing).
- Transcription is automatic when the call ends: Hebrew with the ivrit.ai model, English with Whisper, detected automatically, also mixed calls.
- The transcript shows who said what: "אני" (blue) and "הצד השני" (orange), with timestamps; click a line to hear it. Search across all calls. Recordings can be named automatically from the calendar.
- 100% local and free: nothing leaves the Mac, no account, no subscription.
- Requirements: Apple Silicon Mac, macOS 14.2+.

## The video

- Length 25 seconds (30 max). Language: Hebrew (RTL), product name "CallRec" in Latin letters. Tone: a slick, modern product ad (think Apple keynote / Linear launch video), energetic but clean. No em dashes in any text.
- 16:9, designed at 1920x1080, scaling to fit any window.
- Visual identity: dark background, the app icon is a dark rounded square with a white waveform and a small red dot. Accent colors blue (#0A84FF, "אני") and orange (#FF9F0A, "הצד השני"). Font: Heebo or Rubik from Google Fonts.
- Suggested storyboard (improve it if you have a better idea):
  1. Hook (0-4s): "כל שיחה. מתומללת." / "בלי בוט בפגישה."
  2. How (4-10s): a stylized Mac menu bar, the cursor clicks the waveform icon, menu with "Start recording", then a big "⌃⌥R" keycap.
  3. Anywhere (10-14s): app names (Zoom, Meet, Slack, Teams, WhatsApp, FaceTime) as text chips (no logos), "עם אוזניות או בלי".
  4. Result (14-21s): a transcript window builds up line by line, blue "אני" and orange "הצד השני" lines, one English line too, a "עברית + English" badge.
  5. Trust + CTA (21-25s): "חינם. מקומי. פרטי. שום דבר לא יוצא מהמחשב." then the icon + "CallRec".
- Use mocked UI drawn in HTML/CSS/SVG. Use sample dialogue that is generic (a project sync), not real people or companies.

## Deliverables

1. `index.html`: a single self-contained file (inline CSS/JS, only Google Fonts external) that plays the animation automatically, with a small replay control that hides after a moment. Drive the whole animation from one timeline function `render(t)` (t in seconds), so any frame can be shown exactly; support `index.html?t=12.5` to freeze on a frame.
2. `promo.mp4`: render the animation to H.264 MP4, 1920x1080, 30 fps, by capturing frames of `render(t)` with headless Chrome (Puppeteer or Playwright installed locally in this folder is fine) and assembling with ffmpeg (already installed). Add no audio, or a subtle royalty-free-safe generated tone only if trivial. Keep it under ~10 MB so it can be sent on WhatsApp.
3. `poster.png`: a nice still frame (for a thumbnail).
4. Look at several captured frames yourself (as images) and fix layout problems: Hebrew must render right-to-left correctly, no clipped or overlapping text, nothing flipped.

When done, print a short summary: files made, length, size, and anything you could not do.
