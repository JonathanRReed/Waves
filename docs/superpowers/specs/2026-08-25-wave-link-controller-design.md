# Wave Link Controller and Compatibility Design

## Goal

Let Waves and Elgato Wave Link run together while the user chooses which app
owns ordinary per-app audio control. Waves remains the default controller. Wave
Link can continue to provide effects, Stream Deck integration, monitor routing,
and the stream mix.

## Settings

Settings > Mixer contains a Wave Link section with:

- **Wave Link compatibility**, enabled by default.
- **Per-app controller**, with Waves as the default and Elgato Wave Link as the
  alternative.

Changing either setting persists immediately and rebuilds managed routes.

## Routing Policy

With compatibility enabled and Waves selected, Waves ignores Wave Link claims
for ordinary apps and continues to provide per-app volume and equalization. It
still refuses to wrap Wave Link's mixed output.

With compatibility enabled and Elgato Wave Link selected, verified Wave Link
claims make affected ordinary apps monitor-only in Waves. Wave Link's mixed
output remains excluded.

With compatibility disabled, Waves bypasses all Wave Link-specific conflict
handling, including the mixed-output safeguard. The interface warns that a
custom workaround can then create duplicate or silent audio.

## Intended Signal Path

For the default configuration:

`App -> Waves volume and EQ -> Wave Link virtual channel -> Wave Link monitor and stream mix`

The same app should not be assigned independently through both mixers.

## Verification

Tests cover additive preference decoding, startup ordering, immediate route
recovery, runtime controller changes, ordinary-app ownership, mixed-output
exclusion, and the explicit compatibility opt-out.
