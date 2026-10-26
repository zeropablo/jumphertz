# FAQ and troubleshooting

## FAQ

### Why does Activity Monitor show about 2 % CPU for Jumphertz during a call?

While Discord runs, Jumphertz resamples the microphone in real time with libsamplerate (medium quality), to
absorb the drift between the interface's clock and BlackHole's. That costs about 0.4 % of a performance core.
macOS runs this light real-time thread on an efficiency core, where the same work takes about four times as
long but uses much less energy; Activity Monitor shows time, not energy, hence ~2 %. The energy impact is
negligible.

When Discord is not running, Jumphertz does nothing: no audio thread, no timer, 0.0 % CPU.

### Does Jumphertz change my Scarlett's settings?

No. It reads the interface's sample rate and follows it; it never writes it. It sets BlackHole 2ch to 48 kHz,
and only while Discord is not running (Discord loses its microphone when the input format changes during a
call).

### Can I use another DAW at the same time?

Yes. If the DAW switches the Scarlett to another sample rate (for example a 44.1 kHz project), Jumphertz
rebuilds its input in under a second; Discord keeps its microphone.

## Troubleshooting

### Installation fails after a macOS update

Typical symptoms: `Package.swift: error: extra argument 'swiftLanguageModes' in call`, or compiler / SDK
errors during `scripts/install.sh`. A macOS update can leave Apple's Command Line Tools half replaced (a new
compiler with old pieces; `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` may then report no receipt).
`scripts/install.sh` checks this before building and prints the fix. Reinstall the tools (your Mac password is
requested), then run the installer again:

```sh
sudo rm -rf /Library/Developer/CommandLineTools
xcode-select --install
```

If Xcode is installed and selected instead (`xcode-select -p` shows a path inside `Xcode.app`), update Xcode or
switch to the Command Line Tools: `sudo xcode-select --switch /Library/Developer/CommandLineTools`.

### `jumphertz: command not found`

`~/.local/bin` is not in your PATH. Run once:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

The full path always works: `~/.local/bin/jumphertz --status`.

### Discord hears nothing

1. Discord › Settings › Voice & Video › Input Device must be **BlackHole 2ch**, NOT your Scarlett: BlackHole is
   how Jumphertz sends your voice to Discord. This is the most common cause.
2. `jumphertz --status`: `State: running`, `Microphone: granted`, both `Output` and `Input` active.
3. `Microphone: DENIED`: System Settings › Privacy & Security › Microphone › enable **Jumphertz**.
4. Wrong input on the Scarlett: `jumphertz --list-devices` shows the valid channels, then
   `jumphertz --set-channel N`.

### `No Focusrite Scarlett connected`

Check the USB cable and that the Scarlett appears in Audio MIDI Setup. `jumphertz --list-devices` lists what
Jumphertz detects. Only Focusrite Scarlett interfaces are supported.

### `BlackHole 2ch not found`

```sh
brew install blackhole-2ch
```

then restart the Mac.

### `BlackHole format changes while Discord running` is not 0

Another app (Audio MIDI Setup, a DAW using BlackHole 2ch, a Multi-Output Device containing it) changed
BlackHole 2ch while Discord was running. Discord may have lost its microphone: leave and rejoin the voice
channel. Keep BlackHole 2ch for Jumphertz only (use BlackHole 16ch for other routing).

### Reporting a problem

```sh
jumphertz --diagnose
```

writes `~/Desktop/jumphertz-diagnose-<date>.txt` with your Mac model, macOS version, Jumphertz and BlackHole
versions, the current state, the devices, the configuration and the last hour of logs. Your user name, home
paths, host name and device serial numbers are masked; open the file to check it before attaching it to an
issue.

### Reading the logs

Jumphertz logs to the unified log under the subsystem `com.zeropablo.jumphertz`. Important events are stored
on disk and can be read after the fact: Discord detected / quit, sleep and wake, every rebuild with its cause,
recovery times, underruns and overflows, BlackHole format changes while Discord runs, and errors.

Use the full path `/usr/bin/log`: in zsh (the default macOS shell), a plain `log` is a different, built-in
command.

Last two hours:

```sh
/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.jumphertz" AND process == "Jumphertz"'
```

Only rebuilds and their cause:

```sh
/usr/bin/log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.jumphertz" AND process == "Jumphertz"' | grep -i -E "rebuild|recovered"
```

Live, including debug details:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.zeropablo.jumphertz" AND process == "Jumphertz"'
```

`jumphertz --status` shows the current state, the cumulated counters (underruns, overflows, rebuilds,
BlackHole format changes while Discord is running) and the latency measured over the last five seconds.
