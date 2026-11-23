# New Vegas Radio

An [Omarchy](https://omarchy.org) bar widget that plays Fallout radio stations while you work, with a green-phosphor terminal tuner for picking them. All ten streams from the fan-run [fallout.fm](https://fallout.fm) are on it.

- **Click** to open the tuner: click a station to play it, or click the one playing to stop it
- **Middle-click** to play or stop without opening it
- **Right-click** for the next station
- **Scroll** to change the volume
- **Hover** to see the station, the song on air and the volume

In the tuner, `↑`/`↓` pick a station, `Enter` or `Space` plays or stops it, `←`/`→` change the volume and `Esc` closes it. The icon is dimmed while the radio is off. The station and volume you last used are remembered in `~/.local/state/omarchy/nv-radio.json`. The song title comes from mpv as it changes, so the widget does no polling.

## Install

```bash
omarchy plugin add https://github.com/spconley98/omarchy-nv-radio.git --enable
```

## Remove

```bash
omarchy plugin remove io.github.spconley98.nv-radio
```

## Requirements

- [mpv](https://mpv.io), which Omarchy installs by default
- An internet connection to reach `fallout.fm:8444`

## Stations

| Station | Game |
|---|---|
| Radio New Vegas | Fallout: New Vegas |
| Galaxy News Radio | Fallout 3 |
| Diamond City Radio | Fallout 4 |
| Classical Radio | Fallout 4 |
| More Where That Came From (expanded Diamond City Radio) | Fallout 4 |
| Appalachia Radio | Fallout 76 |
| Classical Radio | Fallout 76 |
| Fallout 2 Soundtrack | Fallout 2 |
| Fallout Soundtrack | Fallout |
| Fallout.FM Mix | All games |

Stations that are mostly talk, such as Enclave Radio, Freedom Radio and Black Mountain Radio, have no public stream, so they aren't included.

## Disclaimer

This is an unofficial fan project. It is not affiliated with or endorsed by Bethesda Softworks, ZeniMax Media or Microsoft. Fallout and Fallout: New Vegas are their trademarks. The plugin contains no game audio: it plays the public streams run by fallout.fm, and what those streams play is up to fallout.fm.

## License

MIT
