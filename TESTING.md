# Testing Jumphertz

Thank you for testing! You need a Mac, a Focusrite Scarlett with a microphone, and Discord. No technical
knowledge is required: each test says what to do, what should happen, and what to do if it doesn't.

When you are done (even if you only did a few tests), open a
[Test report](https://github.com/zeropablo/jumphertz/issues/new?template=test_report.md) and attach
the file created by `jumphertz --diagnose` (it's on your Desktop; your user name and serial numbers are
masked, open it to check).

**If a test fails:** run `jumphertz --diagnose` right away (it includes the last hour of logs), note the time,
and continue with the other tests if you can.

---

### Test 0 — Your setup

Write down for the report:

- [ ] Scarlett model and generation (e.g. "Scarlett 2i2 4th Gen", printed on the box or under the device)
- [ ] macOS version (Apple menu  › About This Mac)
- [ ] Mac type: Apple Silicon (M1, M2, M3, M4…) or Intel (same window)
- [ ] Discord variant: Discord, Discord PTB or Discord Canary

### Test 1 — Installation

- **Do:** follow the [README](README.md) installation from the start, including the prerequisites: Apple
  Command Line Tools (`xcode-select --install`), `brew install blackhole-2ch`, and **restarting the Mac** after
  BlackHole. Then run `jumphertz --status`.
- **Expected:** `Agent: running`, `LaunchAgent: loaded`, `Microphone: granted`.
- **If it fails:** copy everything `scripts/install.sh` printed into your report. `command not found`: do
  step 4 of the README (PATH). `Microphone: DENIED`: System Settings › Privacy & Security › Microphone ›
  enable Jumphertz.

### Test 2 — Discord microphone test

- **Do:** Discord › Settings › Voice & Video: Input Device = **BlackHole 2ch** (NOT your Scarlett: BlackHole is
  how Jumphertz sends your voice to Discord), Noise Suppression = **None**.
  Click **Let's Check** (mic test) and talk.
- **Expected:** your voice comes back clean, in both ears, without stuttering or robotic sound.
- **If it fails:** first check that Discord's Input Device is **BlackHole 2ch**. Then run
  `jumphertz --list-devices` (is your Scarlett listed?) and `jumphertz --status`.
  Silence: your mic may be on another input, see test 3.

### Test 3 — Change the input channel during a call

- **Do:** join a voice channel and keep talking. Run `jumphertz --set-channel 2`, then
  `jumphertz --set-channel 1` (use the input your mic is plugged into; `jumphertz --list-devices` shows the
  valid range).
- **Expected:** the message says "Applied live by the agent, without interruption". Your voice switches to
  the other input instantly, without a dropout. `jumphertz --status` still shows `Rebuilds: input 0, output 0`.
- **If it fails:** note the exact message, then `jumphertz --diagnose`.

### Test 4 — Change the gain during a call

- **Do:** in a call, run `jumphertz --set-gain -6`, then `jumphertz --set-gain 0`.
- **Expected:** you get quieter, then back to normal, without a dropout.
- **If it fails:** note the exact message, then `jumphertz --diagnose`.

### Test 5 — Sample rate change during a call

- **Do:** in a call, while talking, open a 44.1 kHz project in a DAW (Logic, GarageBand, Ableton, Reaper…) or
  change the Scarlett to 44100 Hz in Audio MIDI Setup (Applications › Utilities), then back to 48000 Hz.
- **Expected:** your voice comes back by itself within about 2 seconds, **without leaving the voice channel**.
  In Audio MIDI Setup, **BlackHole 2ch stays at 48,000 Hz**. `jumphertz --status` shows
  `BlackHole format changes while Discord running: 0`.
- **If it fails:** note whether Discord's voice indicator turned off, for how long, and whether you had to
  leave the channel; then `jumphertz --diagnose`.

### Test 6 — Unplug and plug back the Scarlett during a call

- **Do:** in a call, unplug the Scarlett's USB cable, wait 5 seconds, plug it back.
- **Expected:** silence while unplugged, then your voice comes back by itself, without leaving the channel.
- **If it fails:** `jumphertz --status` (look at `State`), then `jumphertz --diagnose`.

### Test 7 — Sleep and wake

- **Do:** with Discord open, put the Mac to sleep (Apple menu  › Sleep), wait 30 seconds, wake it. Rejoin
  the voice channel if Discord left it (Discord does that on sleep).
- **Expected:** your voice works without restarting anything.
- **If it fails:** `jumphertz --status`, then `jumphertz --diagnose`.

### Test 8 — 30-minute call (OPTIONAL)

- **Do:** stay 30 minutes in a voice channel, talking from time to time; then run `jumphertz --status`.
- **Expected:** no clicks or dropouts. `Underruns: … 0 since the input leg started`,
  `Overflows: … 0 since the input leg started`.
- **If it fails:** note when you heard a problem, then `jumphertz --diagnose`.

### Test 9 — Discord closed

- **Do:** quit Discord (⌘Q), then run `jumphertz --status` and look at Jumphertz in Activity Monitor.
- **Expected:** `State: idle`, `Output: inactive`, `Input: inactive`, and **0.0 %** CPU. (About 2 % during a
  call is expected and harmless, see the [FAQ](docs/troubleshooting.md).)
- **If it fails:** `jumphertz --diagnose`.

### Test 10 — Uninstall

- **Do:** `cd ~/jumphertz && scripts/uninstall.sh` (answer `y` to delete the configuration).
- **Expected:** `jumphertz --status` now says `command not found`; `~/Applications/Jumphertz.app` and
  `~/Library/Application Support/Jumphertz` no longer exist.
- **If it fails:** copy what `scripts/uninstall.sh` printed into your report.
