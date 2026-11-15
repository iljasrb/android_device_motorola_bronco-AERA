# TODO

Open work, in priority order. Each item names the evidence it is based on so it
does not become folklore.

## Audio output in recovery

State: **not working**. `aeraui/features/audio/null_bridge.c` is the silent
fallback; the plugin protocol (`aera-browser-audio-v1`, 48 kHz stereo s16) is
accepted and the PCM is discarded.

Current evidence:
- The kernel registers the audio drivers (`waipio-asoc-snd`, `wcd938x_codec`,
  `swr-wcd`, `lpass-cdc`, `lpass_cdc_*`), but there are **no matching platform
  devices** under `/sys/bus/platform/devices`; `/sys/kernel/debug/devices_deferred`
  is empty.
- The recovery DTB contains the DAI nodes (`qcom,msm-dai-q6`, `qcom,msm-dai-tdm`,
  `qcom,msm-dai-mi2s`, `vote_lpass_*`) but no sound machine/codec/SoundWire/
  lpass-cdc nodes.
- `machine_dlkm`, `wcd938x_dlkm`, `swr_dlkm` and `lpass_cdc_*` load, but
  `/proc/asound/cards` stays empty and `/dev/snd` has only `timer`.
- `gpr_send_pkt: Still Dsp is not Up` and `hap-swr-slave-reg: disabling` are
  downstream symptoms of the missing machine/codec devices.
- `/vendor/etc/audio/sku_cape*` and `/vendor/lib64/hw` hold the config/HAL;
  `/vendor` must not be mounted before decryption.

Plan, in order. Stop as soon as a step proves the approach impossible.

- [x] **1a — read-only investigation.** Done: the drivers exist, the platform
      devices and DTB nodes do not.
- [ ] **1b — DTB experiment.** Use a DTB with the sound nodes enabled (the stock
      A17 `vendor_boot`) or add the machine/codec/SoundWire/lpass-cdc nodes, then
      load the audio modules and check `/proc/asound/cards`. Avoid touching
      remoteproc; restarting the ADSP hung the recovery shell once.
- [ ] **1c — wire in only if 1b yields a card.** Guarded so a missing card keeps
      today's silent fallback, and so zip installs still see `/vendor` released.
- [ ] **1d — real PCM bridge.** Replace `null_bridge.c` with tinyalsa
      `pcm_open`/`pcm_write`, card selection with a fallback list, and volume
      control. `external/tinyalsa` needs `recovery_available` added to
      `libtinyalsa`.
- [ ] **1e — test.** Browser video audio, media plugin playback, doom; confirm
      the silent fallback still engages when no card is present.

## Known limitations

- Sideload restarts recovery; Wi-Fi comes back off.
- `fastboot -w` and `getvar partition-size:userdata` fail while userdata is
  mapped; `getvar all` is reduced to `unlocked:yes`.
- Only the first decrypt per boot is guaranteed.
- Mobile data not implemented.
- Secondary users / work profiles, logical-partition write in fastbootd and
  fastboot over Wi-Fi are untested.
