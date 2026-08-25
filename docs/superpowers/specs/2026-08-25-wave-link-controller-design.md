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

With compatibility enabled and Waves selected, Waves manages ordinary apps only
when a verified Wave Link path cannot bypass its renderer. Apps with a parallel
Wave Link path become monitor-only instead of showing a managed level that does
not control every audible copy. Waves also refuses to wrap Wave Link's mixed
output.

With compatibility enabled and Elgato Wave Link selected, verified Wave Link
claims make affected ordinary apps monitor-only in Waves. Wave Link's mixed
output remains excluded.

With compatibility disabled, Waves bypasses all Wave Link-specific conflict
handling, including the mixed-output safeguard. The interface warns that a
custom workaround can then create duplicate or silent audio.

## Intended Signal Path

For the default configuration:

`App -> Waves volume and EQ -> selected output`

Wave Link can continue handling microphone effects, Stream Deck actions, and
stream mixes. The same app must not be monitored independently through both
mixers. When a custom Wave Link setup already prevents that second copy, the
user can disable compatibility to force the Waves route.

## Verification

Tests cover additive preference decoding, startup ordering, immediate route
recovery, runtime controller changes, ordinary-app ownership, mixed-output
exclusion, and the explicit compatibility opt-out.
