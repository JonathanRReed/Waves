# macOS Release Notes

Waves now builds these local release artifacts successfully:

- `src-tauri/target/release/waves`
- `src-tauri/target/release/bundle/macos/Waves.app`
- `src-tauri/target/release/bundle/dmg/Waves_0.1.0_arm64.dmg`

For public distribution, one external step still remains: Apple signing and notarization.

## Signing

Tauri supports macOS signing with either:

- `bundle.macOS.signingIdentity` in `src-tauri/tauri.conf.json`
- the `APPLE_SIGNING_IDENTITY` environment variable

You can inspect available identities locally with:

```bash
security find-identity -v -p codesigning
```

## Build

Tauri's documented macOS distribution flow supports bundling `.app` and `.dmg` artifacts directly. Waves currently uses:

```bash
bun run release:app
bun run release:dmg
```

## Verify Before Distribution

After signing and notarization are configured in your release environment, verify the output before shipping:

```bash
codesign --verify --deep --strict --verbose=2 src-tauri/target/release/bundle/macos/Waves.app
spctl --assess --type execute --verbose=4 src-tauri/target/release/bundle/macos/Waves.app
```

Without Apple credentials and certificates, signing/notarization cannot be completed from this repo alone.
