# Mac mini Elgato inventory receipt

Recorded: 2026-09-04
Codex task: `01a06d9e-6bd2-71d1-8984-11145d8d22c4`

The remote task performed read-only checks. It did not install, launch, quit,
configure, or modify software or hardware.

## Host

- Mac mini `Mac16,10`
- Apple M4
- 16 GB memory
- macOS 27.0 build `26A5406e`
- `arm64`

## Elgato environment

- `/Applications/Elgato Wave Link.app`: version 3.2.2 build 2896, universal.
- Wave Link was active under launchd from the installed bundle.
- `/Applications/Elgato Stream Deck.app`: version 7.5.0 build 22885, universal.
- Stream Deck was active under launchd from the installed bundle.
- `ioreg` reported an active physical Elgato Stream Deck Plus.
- Elgato's Wave Link Stream Deck plugin was installed at
  `~/Library/Application Support/com.elgato.StreamDeck/Plugins/com.elgato.wave-link.sdPlugin`.

The hardware serial is intentionally omitted from this committed receipt.

## Waves state and boundary

- `/Applications/Waves.app`: version 1.7.0 build 18, universal.
- `/Users/jonathan/Downloads/waves` is heavily diverged from its remote.
- The clean `waves-wave-link` worktree is an older 1.7.0 build 18 test branch.
- The separate Waves Stream Deck companion checkout was absent.

Neither Mac mini checkout is release authority. The 1.7.1 candidate and exact
companion package must be built from their canonical repositories, sealed on
the build host, and transferred through the supported Elgato handoff kit.

## Gate result

The Mac mini is hardware-suitable for the no-waiver Wave Link and Stream Deck
release gate. Functional testing remains pending until the exact 1.7.1 build 19
candidate and companion package are available.
