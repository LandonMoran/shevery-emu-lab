# shevery-emu-lab

Live Android emulator sessions for testing Shevery builds. Manual runs only,
so nobody gets failure-spam while this is being iterated on.

## Secrets (Settings > Secrets > Actions)

| Name | Value |
|---|---|
| `TAILSCALE_AUTHKEY` | Reusable Tailscale auth key (fixed hostname `shevery-emu`) |
| `TAILSCALE_DOMAIN` | Your tailnet domain (for the web-view URL) |
| `TEST_API_KEYS` | Test-only provider keys, e.g. `GEMINI_KEY=... OPENROUTER_KEY=...` |

Keys arrive via env at run time and are pushed to the emulator over ADB.
They never touch git, the APK, or logs.

## Run

Actions > `emu-session` > Run workflow. Then:

- Web view: `https://shevery-emu.<your-tailnet>/`
- ADB: `adb connect shevery-emu:5555`
- Screenshot any time: `adb -s shevery-emu:5555 exec-out screencap -p > shot.png`

## Notes

- Emulator image is a Play Store (unrooted) build, so it behaves like a real
  user device. Wireless-debugging pairing still can't be tested here (fake
  WiFi) — that flow needs physical hardware.
- Session holds up to ~5.5h, then the runner dies.
