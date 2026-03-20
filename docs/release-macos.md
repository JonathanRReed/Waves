# macOS Release Notes

## Current macOS Status

Waves now ships macOS with a real virtual-device engine:

- true per-app volume is handled through the Waves virtual audio device
- live app discovery is driven by the driver session list
- hardware output selection now targets the physical playback device behind Waves
- the app bundle includes the installable `WavesAudio.driver` payload

The previous tap-only path remains in the codebase only as a safety fallback when the virtual device is not installed or not loaded.

Waves now builds these local release artifacts successfully:

- `src-tauri/target/release/waves`
- `src-tauri/target/release/bundle/macos/Waves.app`
- `src-tauri/target/release/bundle/dmg/Waves_0.1.0_arm64.dmg`

The packaged app embeds the driver bundle at:

- `src-tauri/target/release/bundle/macos/Waves.app/Contents/Resources/macos/WavesAudio.driver`

For public distribution, two external steps still remain:

- Apple signing and notarization for the app
- signed installation flow for the HAL driver

## Signing

Tauri supports macOS signing with either:

- `bundle.macOS.signingIdentity` in `src-tauri/tauri.conf.json`
- the `APPLE_SIGNING_IDENTITY` environment variable

You can inspect available identities locally with:

```bash
security find-identity -v -p codesigning
```

## Build

Waves currently uses:

```bash
./scripts/build-macos-driver.sh
bun run release:app
bun run release:dmg
```

The DMG build script now embeds the driver bundle into the app resources automatically.

## Verify Before Distribution

After signing and notarization are configured in your release environment, verify the output before shipping:

```bash
codesign --verify --deep --strict --verbose=2 src-tauri/target/release/bundle/macos/Waves.app
spctl --assess --type execute --verbose=4 src-tauri/target/release/bundle/macos/Waves.app
```

Without Apple credentials and certificates, full production signing/notarization cannot be completed from this repo alone.
