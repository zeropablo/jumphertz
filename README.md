# Jumphertz

**Jumphertz — clean Focusrite Scarlett mic in Discord on macOS**

Discord's microphone input stutters with Focusrite Scarlett interfaces on macOS. Jumphertz routes your Scarlett
microphone to the BlackHole 2ch virtual device, cleanly and in the background, and you pick "BlackHole 2ch" as
Discord's input.

**Jumphertz does not modify Discord and does not interact with it.** It provides a virtual microphone at the
macOS level (BlackHole 2ch, fed by Jumphertz), which Discord uses like any other microphone. There is no risk with regard to Discord's Terms of
Service.

> Beta: installation, configuration and the full documentation come with the first release.

## FAQ

### Why does Activity Monitor show about 2 % CPU for Jumphertz during a call?

While Discord runs, Jumphertz resamples the microphone in real time with libsamplerate (medium quality, to
absorb the drift between the interface's clock and BlackHole's). That costs about 0.4 % of a performance core.
macOS runs this light real-time thread on an efficiency core, where the same work takes about four times as
long but uses much less energy; Activity Monitor shows time, not energy, hence ~2 %. The energy impact is
negligible.

When Discord is not running, Jumphertz does nothing: no audio thread, no timer, 0.0 % CPU.

## Troubleshooting

### Reading the logs

Jumphertz logs to the unified log under the subsystem `com.zeropablo.jumphertz`. Important events are stored
on disk and can be read after the fact: Discord detected / quit, sleep and wake, every rebuild with its cause,
recovery times, underruns and overflows, BlackHole format changes while Discord runs, and errors.

Last two hours (attach this to GitHub issues):

```sh
log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.jumphertz"'
```

Only rebuilds and their cause:

```sh
log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.jumphertz"' | grep -i -E "rebuild|recovered"
```

Live, including debug details:

```sh
log stream --level debug --predicate 'subsystem == "com.zeropablo.jumphertz"'
```

`jumphertz --status` shows the current state, the cumulated counters (underruns, overflows, rebuilds,
BlackHole format changes while Discord is running) and the latency measured over the last five seconds.
