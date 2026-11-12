# callrec

Record every call on your Mac and get a transcript, automatically. Free, fully local, no bot joins the meeting.

- Works with Zoom, Google Meet, Slack huddles, Teams, FaceTime, WhatsApp, Discord, Webex, and any browser call.
- Works with headphones, AirPods or speakers, and keeps recording if you plug in or unplug them mid-call.
- Hebrew is transcribed with the [ivrit.ai](https://huggingface.co/ivrit-ai) model, English with Whisper large-v3-turbo. The language is detected automatically, also when a call switches between Hebrew and English.
- Speakers: "you" (your mic) and "the other side" (what your Mac plays). Click a name in the transcript to rename it.
- Nothing leaves your computer.

## Before you record

Recording laws differ by country, and in some places by state. In Israel a participant may record a conversation they take part in; elsewhere you may need everyone's consent, and your workplace may have its own rules. You are responsible for following the laws and policies that apply to you and to the people on the call. When in doubt, tell everyone at the start that you are recording.

## Install

Open Terminal and paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/shacharPash/callrec/main/install.sh)"
```

Needs an Apple Silicon Mac (M1 or newer) and macOS 14.2 or newer. No Homebrew, no admin password.

The command installs the CallRec app in Applications (or `~/Applications` if you can't write to Applications), its tools in `~/.callrec/bin` (uv, ffmpeg, ffprobe, whisper-cli), the transcription models in `~/.callrec/models` (about 2.5 GB, once; an ivrit.ai model you already have from OpenSuperWhisper or Vibe is reused) and the `callrec` command, then opens the app. Every file the installer downloads is pinned to an exact version and checked with sha256, and an interrupted model download resumes when you run the command again. On the first run, uv also downloads Python and the [catap](https://pypi.org/project/catap/) package for the CallRec engine. To update, run the same command again.

The first time CallRec opens it records a 5 second test, and macOS asks for **Microphone** and **System Audio Recording** access. Allow both.

Good to know about the install:

- CallRec is not signed with an Apple developer account. Files downloaded with `curl` are not marked as downloaded from the internet, so macOS opens the app without the "Open Anyway" step. (If you download `CallRec.zip` from the Releases page in a browser instead, macOS blocks it the first time: open System Settings > Privacy & Security and click **Open Anyway**. Then choose **Finish setup** in the menu bar icon.)
- The same missing developer signature means that to macOS every update is a new app, so after an update it may ask for Microphone and System Audio Recording again.
- Where the tools come from: uv is the official release from Astral. ffmpeg 9.0.2 (LGPL, only macOS frameworks) and whisper-cli 1.9.5 (Metal) are built from their official sources by [tools/build-tools.sh](tools/build-tools.sh); the exact sources, checksums and licenses are in `~/.callrec/licenses`. The models come from fixed revisions on Hugging Face.
- To uninstall: if you turned on **Open at login**, turn it off in the menu first. Quit CallRec, delete it from Applications, then run this in Terminal to remove the `callrec` command, the tools and models, and the app settings:

  ```bash
  for f in ~/.local/bin/callrec /opt/homebrew/bin/callrec /usr/local/bin/callrec ~/bin/callrec; do [ "$(readlink "$f")" = "$HOME/.callrec/bin/callrec" ] && rm "$f"; done; rm -rf ~/.callrec; defaults delete app.callrec.CallRec
  ```

  Your recordings in `~/CallRecordings` stay. If you added `~/.callrec/bin` to `~/.zprofile`, remove that line. uv keeps the Python it downloaded under `~/.local/share/uv` and `~/.cache/uv`; delete those only if you don't use uv for anything else.

## בעברית, בקצרה

מתקינים בפקודה אחת בטרמינל, בלי Homebrew ובלי סיסמת מנהל:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/shacharPash/callrec/main/install.sh)"
```

אחרי ההתקנה האפליקציה יושבת בשורת התפריטים. מתחילים הקלטה מהאייקון או עם Ctrl+Option+R, או מדליקים "Start automatically when a call starts" ואז כל שיחה (זום, מיט, סלאק, טימס, וואטסאפ ועוד) מוקלטת לבד: ההקלטה מתחילה כשהשיחה מתחילה, נעצרת כשהיא נגמרת, והתמלול מוכן כעבור כמה שניות. עברית מתומללת עם ivrit.ai ואנגלית עם Whisper, והכל נשאר על המחשב. לעדכון מריצים שוב את אותה פקודה, ואחרי עדכון ייתכן שמקוס יבקש שוב הרשאה למיקרופון ולהקלטת שמע.

חשוב לדעת: בישראל מותר למשתתף בשיחה להקליט אותה, אבל במדינות אחרות ייתכן שצריך הסכמה של כל המשתתפים, ולמקום העבודה עשויים להיות כללים משלו. האחריות לעמוד בחוק ובכללים היא שלכם, ובמקרה של ספק כדאי לומר בתחילת השיחה שהיא מוקלטת.

## The app

From the menu bar icon (or **Ctrl+Option+R** from anywhere): **Start recording**, **Stop recording**. **Show all recordings…** opens a window with every call: details (date, duration, app, language, model, mic and headphones), the transcript, a player (click a line to jump there), search, Rename, and Move to Trash. To transcribe a recording you already have (a phone call, a voice memo, an exported meeting), drag the file into that window or choose **Import recording…**. Turn on **Name recordings from Calendar** in the menu and each recording is named after the meeting on your calendar at that time (asks for Calendar access once; works with any calendar added to the macOS Calendar app).

CallRec lives in the menu bar only (no Dock icon). If you don't see its icon, the menu bar may be full and the notch hides it: open CallRec again from Spotlight or Applications and the Recordings window opens.

Muted yourself in the meeting to talk to someone in the room? Press **Ctrl+Option+M** (or Mute me in the recording in the menu): your mic is silent in the recording until you press it again, the other side keeps recording, and the icon shows a crossed-out mic. The meeting apps don't tell other apps when you mute, so this is a separate switch.

While recording, the icon only turns filled, with no timer and no pop-ups, so it stays out of the way when you share your screen. That keeps your screen clean; it is not a way to record people without telling them (see [Before you record](#before-you-record)). A recording stops by itself 5 minutes after the call app is gone, or after 15 minutes with nothing heard on either side.

## Command line

The installer also adds the `callrec` command. If a new Terminal window says `command not found`, run this once and open a new window:

```bash
echo 'export PATH="$HOME/.callrec/bin:$PATH"' >> ~/.zprofile
```

Without the app, from a clone of this repo, `./setup.sh` installs the same tools, models and command.

The first time you record from the Terminal, macOS asks your terminal app for **Microphone** and **System Audio Recording** access. Allow both, quit the terminal, and open it again.

## Use

```bash
callrec                 # auto mode: leave it running; every call is recorded and transcribed
callrec daily           # record right now (stops on Enter, or when the meeting ends)
callrec list            # what you recorded, with duration, language and a preview
callrec import x.m4a    # add any audio/video file to your recordings and transcribe it
callrec transcribe x.m4a  # transcribe a file, transcript saved next to it
callrec recover         # finish a recording that was cut off
callrec doctor          # check setup
```

In auto mode: Enter stops the current recording early, Ctrl+C turns callrec off. Closing the terminal is safe: the recording is saved and transcribed anyway.

Each call goes to `~/CallRecordings/<date>_<time>_<app>/`:

- `call.transcript.md`: the transcript, with date, duration, app, language, model and devices at the top
- `call.m4a`: stereo audio, left = you, right = the other side (kept as `call.wav` until transcribed, then compressed)
- `call.transcript.srt`: subtitles with timestamps

## How it works

- Your mic: `ffmpeg` (AVFoundation), always the current default mic. If the mic disappears mid-call (AirPods disconnected), it restarts on the new default and the pieces are stitched back in time.
- The other side: a private Core Audio process tap via [catap](https://pypi.org/project/catap/). It captures what the Mac plays on any output device, does not change your audio settings, and other apps cannot see it.
- Meeting detection: callrec polls which apps are using the microphone. A known call app (or a browser) using the mic starts a recording; 60 seconds (5 minutes in the app) with the app no longer using the mic or playing audio ends it.
- Transcription: `whisper.cpp` with Silero VAD (skips silence, so Whisper doesn't invent text), stereo diarization for "me / them", and the right model for each language. Long calls are checked every 30 seconds, so a stretch of English inside a Hebrew call goes to the English model.

## Settings (optional, env vars)

| Variable | Default | |
|---|---|---|
| `CALLREC_DIR` | `~/CallRecordings` | where recordings go |
| `CALLREC_LANG` | `auto` | force `he` or `en` |
| `CALLREC_MIC` | `default` | mic name or index from `callrec doctor` |
| `CALLREC_END_GRACE` | `60` (app: `300`) | seconds after the call app is gone before auto stop |
| `CALLREC_SILENCE_STOP` | `900` | seconds with nothing heard on either side before auto stop |
| `CALLREC_ME` / `CALLREC_THEM` | by language | speaker labels |

## Building and releasing

- `app/build.sh`: builds `CallRec.app` and `build/CallRec.zip` (needs only the Xcode Command Line Tools).
- `./release.sh`: builds the app, pins its sha256 in `install.sh`, lays the files out as a local release to test the installer against (`CALLREC_RELEASE_URL=file://...`), and prints the commands that publish it. It does not publish anything itself.
- The tools (ffmpeg, ffprobe, whisper-cli) were built once and stay as they are; to rebuild them, raise `TOOLS_REVISION` in `setup.sh` and `tools/build-tools.sh`, set `TOOLS_TAG` in `setup.sh` to the new release, and run `./release.sh`.

## Good to know

- On speakers (no headphones) your mic also hears the other side, so a few of their lines may be labeled as you. Headphones give the cleanest result.
- macOS shows its own recording indicator in the menu bar while callrec records. Only you see it.
- Recording laws differ by country: see [Before you record](#before-you-record).

## License

[MIT](LICENSE). The tools archive in each release has its own licenses: ffmpeg and ffprobe are LGPL 2.1, whisper-cli is MIT (both included in the archive).
