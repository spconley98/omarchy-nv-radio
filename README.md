# New Vegas Radio

An [Omarchy](https://omarchy.org) bar widget that plays Fallout radio stations while you work: Radio New Vegas, Galaxy News Radio, Diamond City Radio and Appalachia Classical, streamed from the fan-run [fallout.fm](http://fallout.fm).

- **Click** to play or stop
- **Right-click** for the next station
- **Scroll** to change the volume
- **Hover** to see the station, the song on air and the volume

The icon is dimmed while the radio is off. The station and volume you last used are remembered in `~/.local/state/omarchy/nv-radio.json`. The song title comes from mpv as it changes, so the widget does no polling.

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
- An internet connection to reach `fallout.fm:8000`

## Stations

| Station | Game |
|---|---|
| Radio New Vegas | Fallout: New Vegas |
| Galaxy News Radio | Fallout 3 |
| Diamond City Radio | Fallout 4 |
| Appalachia Classical | Fallout 76 |

## Disclaimer

This is an unofficial fan project. It is not affiliated with or endorsed by Bethesda Softworks, ZeniMax Media or Microsoft. Fallout and Fallout: New Vegas are their trademarks. The plugin contains no game audio: it plays the public streams run by fallout.fm, and what those streams play is up to fallout.fm.

## License

MIT
