# MicBridge

Routes a Focusrite Scarlett microphone input to BlackHole 2ch for Discord on macOS, without Logic Pro or any
other app running in the background.

> Work in progress: installation, configuration and the full documentation come with the first release.

## Troubleshooting

### Reading the logs

MicBridge logs to the unified log under the subsystem `com.zeropablo.micbridge`. Important events are stored
on disk and can be read after the fact: Discord detected / quit, sleep and wake, every rebuild with its cause,
recovery times, underruns and overflows, BlackHole format changes while Discord runs, and errors.

Last two hours (attach this to GitHub issues):

```sh
log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.micbridge"'
```

Only rebuilds and their cause:

```sh
log show --last 2h --style compact --predicate 'subsystem == "com.zeropablo.micbridge"' | grep -i -E "rebuild|recovered"
```

Live, including debug details:

```sh
log stream --level debug --predicate 'subsystem == "com.zeropablo.micbridge"'
```

`micbridge --status` shows the current state, the cumulated counters (underruns, overflows, rebuilds,
BlackHole format changes while Discord is running) and the latency measured over the last five seconds.
