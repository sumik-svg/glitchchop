# glitchchop

**Version 1.7.6**

A live glitch-beat processor for monome norns, built for drum and percussion loops. It loads one sample loop and, while the loop plays straight, chops a second copy of it into glitch beats in real time — position jumps, rate changes and reversed fragments, decided on a 16th-note grid. No custom SuperCollider engine; softcut only.

## How it works

Two stereo voice pairs read the same buffer:

- **voices 1–2 (dry):** the loop, played straight
- **voices 3–4 (glitch):** the same loop, chopped by a 16th-note decision metro
- **voices 5–6:** a dotted-eighth feedback echo fed from the glitch pair, which can also be borrowed for an extra-large flanger (K1+K3)

E1 crossfades between dry and glitch. At mix = 0 you hear the plain loop. The effective glitch amount drifts within ±2% of the set value, so the pattern never repeats exactly.

glitchchop is designed for drums and percussion. Its rate-based effects shift pitch along with speed, which breaks pitched material — for melodic samples, turn **rate variation** off (the position jumps and reverse still work and keep the pitch intact).

## Installation

In maiden:

```
;install https://github.com/sumik-svg/glitchchop
```

Then restart your norns (or SLEEP and wake) and select **glitchchop** from the SELECT menu. Manual installation also works: copy the `glitchchop` folder into `dust/code/` on your norns.

The 15 preset loops are included in `data/`, so it makes sound right away.

## Controls

| Input | Function |
|---|---|
| E1 | mix (dry ↔ glitch) |
| E2 | glitch amount (probability of a glitch event per 16th note) |
| E3 | reverse amount (share of glitch fragments played in reverse; reversed fragments are boosted in level so the flip stands out) |
| K2 | play / stop (stop is a fast ~0.1 s fade-out; press K2 during the fade to resume) |
| K3 (hold) | wild pitch: the glitch pair's pitch jumps randomly every 16th note (−24 to +24 semitones), and the glitch pair gets louder while held |
| K1 + E1 | volume |
| K1 + E2 | filter cutoff (applies to both dry and glitch pairs) |
| K1 + E3 | echo amount (dotted-eighth feedback echo) |
| K1 + K3 (hold) | extra-large flanger (voices 5–6 leave echo duty while held; the echo returns on release) |
| K1 + K2 | arm a full parameter reset: nothing changes until the loop wraps, then all parameters return to their defaults and only the dry loop plays (tempo and loop selection are kept) |

The system reverb is turned off at startup. MIDI clock (start/stop + 24 ppqn) can be sent to an external device; see the parameters below.

## Parameters (PARAMETERS > GLITCHCHOP)

- **loop select** — one of the 15 preset loops, or "custom file". Selecting a preset also sets the tick tempo to that loop's BPM.
- **sample (custom)** — any WAV file of your own. 48 kHz files are recommended; other sample rates are compensated automatically at playback, so loops still close seamlessly at the correct pitch and speed.You can also swap samples freely: replace any file in data/ with your own loop (keep the same filename and it is picked up as that preset), or load any WAV file via PARAMETERS > sample (custom) without replacing anything.
- **mix (dry>glitch)**, **glitch amount**, **reverse amount (E3)**
- **tick tempo** — the tempo of the 16th-note decision grid
- **slice grid** — jump granularity: 1/32, 1/64 or 1/128 of the loop
- **rate variation** — on/off for the temporary rate changes (0.5×, 2×, reverse) on glitch events
- **trim start / trim end** — narrow the playback window (seconds, in buffer time)
- **volume**, **filter cutoff (K1+E2)**, **echo amount (K1+E3)**
- **midi clock out** (off/on), **midi out port** (1–4)
- **debug log** — prints `GCDBG` lines (load/play/wrap timing) to the maiden console

## Preset samples

The 15 loops in `data/` were synthesized from scratch for this project — no recorded material is used — and are released under **CC0** (public domain). You may use and redistribute them freely.

| File | BPM | Style |
|---|---|---|
| loop_01_140.wav – loop_05_140.wav | 140 | glitch percussion (G1–G5) |
| loop_06_90.wav – loop_08_90.wav | 90 | swung beats (G6–G8) |
| loop_09_172.wav, loop_10_172.wav | 172 | fast beats (G9, G10) |
| drum_01_90.wav | 90 | trip hop (D1) |
| drum_02_120.wav | 120 | rock (D2) |
| drum_03_120.wav | 120 | funk disco (D3) |
| drum_04_130.wav | 130 | break, 8 bars (D4) |
| drum_05_160.wav | 160 | drum & bass (D5) |

All presets are 48 kHz / 16-bit stereo, peak-normalized to −1 dB.

## Version history

- **v1.7.6** — E3 is now reverse amount: a share of glitch fragments play in reverse (one slice from its end), and reversed fragments are boosted in level (glitch pair only) so the effect never gets buried. Reverse amount is also covered by the K1+K2 reset.
- **v1.7.5** — K1+K2 arms a parameter reset that fires at the next loop wrap (dry only; tempo and loop selection kept).
- **v1.7.4** — K1+K3 extra-large flanger (0.8–14 ms delay swept by a 0.25 Hz LFO, strong feedback) on the echo voices; the echo pauses while it is held.
- **v1.7.3** — while K3 is held, the pitch-modulated (glitch) pair also gets louder; the dry pair is unchanged.
- **v1.7.2** — stutter removed entirely. K3 is now wild pitch: random semitone jumps (−24…+24) on the glitch pair every 16th note while held.
- **v1.7.1** — stop fade shortened to ~0.1 s; ratchet removed; E3 became stutter amount (later removed in v1.7.2).
- **v1.7.0** — screen layout fix (removed the loop text line), stop fade-out, much stronger filter (60 Hz floor, resonant), K3 ratchet (later removed), E3 scratch (later replaced), glitch amount drift ±2%.
- **v1.6.1** — non-48 kHz custom files are rate-compensated so they loop seamlessly at the correct pitch; the filter now applies to the dry pair as well.
- **v1.6.0** — root cause of the loop-seam gap found: softcut buffers run at 48 kHz and `buffer_read` does not resample, so 44.1 kHz files left ~0.56 s of silence at every wrap. All presets converted to 48 kHz; the seam gap is gone (confirmed on hardware).
- **v1.5.1** — debug build: GCDBG load/play/wrap/stall instrumentation in maiden; loop_08 re-cut to its exact length.
- **v1.5.0** — near-zero loop fade; system reverb off at startup; K1 layer added (K1+E1 volume, K1+E2 filter, K1+E3 dotted-eighth echo); E3 became pitch amount (later replaced).
- **v1.4.0** — MIDI clock output (start/stop + 24 ppqn, follows tick tempo).
- **v1.3.0** — trim start/end parameters.
- **v1.2.1** — sample lookup is relative to the script's own folder, so nested install folders still find `data/`.
- **v1.2.0** — presets lightly compressed and peak-normalized (−1 dB); equal-power mix crossfade; volume range extended to 1.5.
- **v1.1.1** — fixed: choosing a file in "sample (custom)" did not switch the sample while loop select pointed at a preset.
- **v1.1.0** — 15 preset loops with loop select; tick tempo follows the selected loop.
- **v1.0.1** — fixed the cleanup crash (metro must be freed with `metro.free(id)`), explicit master level, softcut reset at startup. First version confirmed playing on hardware.
- **v1.0.0** — first release.

## License

- Script (`glitchchop.lua`): MIT License — see [LICENSE](LICENSE).
- Preset samples (`data/*.wav`): CC0 / public domain.
