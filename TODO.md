# TODO

Open work, in priority order. Each item names the evidence it is based on so it
does not become folklore.

## Audio output in recovery

State: **not working**. `aeraui/features/audio/null_bridge.c` is the silent
fallback; the plugin protocol (`aera-browser-audio-v1`, 48 kHz stereo s16) is
accepted and the PCM is discarded.

Measured in recovery (#87):
- `/dev/snd` contains only `timer`; `/proc/asound/cards` reports no soundcards.
- Only `snd-soc-dummy` is registered on `/sys/bus/platform/drivers`; no ASOC
  machine or codec driver probes.
- ADSP remoteproc is `running` but GPR logs `Still Dsp is not Up`, i.e. the audio
  protection domain never starts, and `hap-swr-slave-reg: disabling` shows the
  SoundWire codec supply never came up.
- `/firmware` is mounted and carries the `adsp.*` images, so firmware is not the
  blocker. No `snd-soc-*`/codec modules exist in `/lib/modules` or
  `/vendor/lib/modules`; they are in-kernel.
- Audio config lives in `/vendor/etc/audio/sku_cape*`, HAL libraries in
  `/vendor/lib64/hw`. `/vendor` is normally released by `wlan-start.sh`, and it
  must never be mounted before decryption (keymaster 4.x would be picked from the
  vendor manifest and metadata decryption fails).

Plan, in order. Stop as soon as a step proves the approach impossible.

- [ ] **1a — read-only investigation, no changes.** Compare with Android: which
      modules Android has loaded (`lsmod`), and whether an ASOC machine driver
      exists in the kernel at all (`/sys/bus/platform/drivers`). If the driver is
      absent, a re-probe is pointless and this needs a different approach.
- [ ] **1b — opt-in experiment.** Manual script (`audio-probe.sh`, invoked by
      hand, never from a boot hook): mount `/vendor` read-only, trigger a single
      machine-driver re-probe, wait ~5 s for `/proc/asound/cards`, release
      `/vendor`, log the outcome. Avoid touching remoteproc: restarting the ADSP
      already hung the recovery shell once.
- [ ] **1c — wire in only if 1b yields a card.** Guarded so a missing card keeps
      today's silent fallback, and so zip installs still see `/vendor` released.
- [ ] **1d — real PCM bridge.** Replace `null_bridge.c` with tinyalsa
      `pcm_open`/`pcm_write`, card selection with a fallback list, and volume
      control. Verify with the browser audio sink and the media plugin.
- [ ] **1e — test.** Browser video audio, media plugin playback, doom; confirm
      the silent fallback still engages when no card is present.

Rollback: reflash `out/AERA-bronco-87-final.img` (md5 `388e3c98…`).

## Fixes found while testing audio

- [ ] `wlan-start.sh` mounts `/dev/block/mapper/vendor$slot` and
      `vendor_dlkm$slot`, but on bronco `vendor` and `vendor_dlkm` are **not**
      slot-suffixed (`/dev/block/by-name/vendor`, `.../vendor_dlkm`). It works by
      luck through the fallback paths; make it try the plain names first.

## Documentation gaps

- [ ] `docs/release-checklist.md`: rows for Format Data (AOSP discard wipe),
      dirty OTA zip flash, sideload OTA, OTA + factory reset, slot switch.
- [ ] XDA post: state that sideload restarts recovery, so Wi-Fi returns disabled
      afterwards (flash from storage if Wi-Fi must stay up).

## Known limitations (unchanged)

- Sideload restarts recovery; Wi-Fi comes back off.
- `fastboot -w` and `getvar partition-size:userdata` fail while userdata is
  mapped; `getvar all` is reduced to `unlocked:yes`.
- Only the first decrypt per boot is guaranteed.
- Mobile data not implemented.
- Secondary users / work profiles, logical-partition write in fastbootd and
  fastboot over Wi-Fi are untested.
