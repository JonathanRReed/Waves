# Waves 1.4.4 persistence fixture

These are field-for-field transcriptions of raw schema-1 envelopes emitted by a
detached build of the exact `v1.4.4` source revision
`64bad3baa901d44d02a64023a9c72acabf0557ea`. JSON whitespace was normalized when
the emitted objects were checked in; no key or value was invented by current
code. The detached build used that revision's `PreferencesStore`,
`ProfileStore`, `SessionStore`, and `DeviceVolumePresetsStore`. Upgrade tests
copy the checked-in bytes directly and never encode them with current store or
model code before the first load.

The keys come from the 1.4.4 encoders:

- `preferences.json`: `VersionedPayload<UserPreferences>` and the 1.4.4
  `UserPreferences.CodingKeys`, including its synthesized hotkey action payload,
  legacy EQ map, adaptive policy, automation preferences, and migration version.
- `profiles.json`: `VersionedPayload<[Profile]>`, with `Profile.CodingKeys` and
  `ProfileEntry.CodingKeys`.
- `session.json`: `VersionedPayload<AudioSessionSnapshot>`, using the 1.4.4
  `SessionStore.persistencePayload`, `AudioApp`, device, support-matrix, and
  backend-status encoders. The legacy session row carries the pin and automatic
  conferencing mute.
- `deviceVolumePresets.json`: `VersionedPayload<DeviceVolumePresets>` with the
  1.4.4 `AppVolumeSettings` fields.
