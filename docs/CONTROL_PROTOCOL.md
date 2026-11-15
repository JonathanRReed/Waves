# Waves control socket, protocol version 1

This is the reference for clients of Waves's local control socket: `wavesctl`,
the Stream Deck plugin, and anything else that runs as the same macOS user. It
describes what Waves actually sends; the source of truth is
`Sources/Waves/Services/Control/ControlProtocol.swift`.

## Turning it on

External control is off by default. The user turns it on in
**Waves ▸ Settings ▸ Shortcuts & Automation ▸ Allow external control**. While it
is off, every request gets `not-permitted`.

## Transport

- Unix domain stream socket at
  `~/Library/Application Support/Waves/control.sock`. Waves opens no network
  port. The socket's directory is private to the user, and Waves checks each
  peer's user ID and drops any connection from a different user.
- Newline-delimited JSON, one UTF-8 object per line. CRLF is accepted and blank
  lines are ignored. A line longer than 64 KiB closes the connection.
- Requests carry a client-chosen integer `id`; the response echoes it, so several
  requests can be in flight. Waves handles one connection's requests in order.
- Unsolicited pushes carry `event` and no `id`.

## Limits

- 8 connections in total, 4 per client process, 2 subscribed connections per
  process.
- Per connection: a burst of 60 requests, refilled at 30 per second, plus a byte
  budget of 256 KiB refilled at 128 KiB per second. Budgets run on a monotonic
  clock, so changing the system time does not refill them. A request over budget
  gets `rate-limited`. The third rejected frame (over budget or not a valid
  request) in a connection's lifetime closes it.
- At most 32 requests (and 256 KiB of them) may be waiting on one connection.
- A connection must send `hello` within 5 seconds. After that, a connection that
  is not subscribed closes after 30 seconds without a request. Subscribed
  connections stay open.

## Handshake and discovering commands

`hello` must be the first request. Anything else before it gets
`malformed-request`.

```text
→ {"id":1,"cmd":"hello","client":"my-plugin","protocol":1}
← {"id":1,"ok":true,"protocol":1,"appVersion":"1.8.0","build":"23",
   "commands":["hello","list-apps","get-icon","set-volume","adjust-volume",
               "set-mute","toggle-mute","subscribe","unsubscribe",
               "apply-profile","refresh","set-boost"]}
```

`protocol` is optional; if present it must be `1`, or the reply is
`unsupported-protocol`.

`commands` lists every command this build accepts. It was added in Waves 1.8.0.
**A reply without `commands` comes from an older Waves that supports only the
first nine commands.** Check this list before sending a newer command: an older
Waves does not recognise the name, replies `malformed-request`, and counts it as
one of the three bad frames that close the connection. Waves 1.8.0 and later
reply `unknown-command` to a well-formed request with a name they do not know,
and do not count it against the connection.

## Commands

Every response has `ok`. A failure looks like:

```text
← {"id":9,"ok":false,"error":"unknown-app","message":"Waves does not know an app with that identifier."}
```

Branch on `error`; show `message` to people.

App identifiers are Waves's logical app IDs (usually the bundle identifier, for
example `com.spotify.client`), as returned by `list-apps`. They stay stable when
an app quits and relaunches. Identifiers longer than 256 characters are refused.

### `list-apps`

```text
→ {"id":2,"cmd":"list-apps"}
← {"id":2,"ok":true,"apps":[{"id":"com.spotify.client","name":"Spotify","running":true,
   "muted":false,"volume":0.8,"live":true,"managed":true}]}
```

`live` means the app is producing audio right now. `managed` means Waves owns its
route, so volume and mute take effect. The list matches the apps the mixer shows.

### `get-icon`

```text
→ {"id":3,"cmd":"get-icon","app":"com.spotify.client"}
← {"id":3,"ok":true,"app":"com.spotify.client","icon":"iVBORw0KGgo…"}
```

A 144×144 base64 PNG, at most 512 KiB of base64. `icon` is absent when the app has
no icon.

### `set-volume`, `adjust-volume`

```text
→ {"id":4,"cmd":"set-volume","app":"com.spotify.client","volume":0.5}
← {"id":4,"ok":true,"app":"com.spotify.client","volume":0.5}

→ {"id":5,"cmd":"adjust-volume","app":"com.spotify.client","delta":-0.02}
← {"id":5,"ok":true,"app":"com.spotify.client","volume":0.48}
```

Volume is linear, `0` to `1`; `1` is the app's own level and Waves never goes
above it. A finite `volume` outside `0…1` is clamped. `adjust-volume` adds `delta`
to the current volume and clamps the result, so a dial never has to read first.
The reply carries the resulting volume. A missing volume or delta is
`missing-parameter`.

### `set-mute`, `toggle-mute`

```text
→ {"id":6,"cmd":"set-mute","app":"com.spotify.client","muted":true}
← {"id":6,"ok":true,"app":"com.spotify.client","muted":true}

→ {"id":7,"cmd":"toggle-mute","app":"com.spotify.client"}
← {"id":7,"ok":true,"app":"com.spotify.client","muted":false}
```

The volume and mute commands reply as soon as Waves accepts the change, the same
moment the mixer's own controls update. Watch `app-changed` pushes to see the
route's confirmed state.

### `set-boost` (Waves 1.8.0)

```text
→ {"id":8,"cmd":"set-boost","app":"com.spotify.client","boost":2}
← {"id":8,"ok":true,"app":"com.spotify.client","boost":2}
```

`boost` is a multiplier from `1` (no boost) to `4`, the same range as the mixer's
Boost menu. Unlike volume, a value outside `1…4` is **refused** with
`invalid-parameter`, never clamped, so a client bug cannot make an app louder than
the person asked for. The same rules as the mixer apply: an excluded app gets
`app-excluded`, and an app whose route Wave Link or route recovery controls gets
`route-unavailable` (the mixer disables Boost for those apps too).

Waves replies after the change has been applied. `ok:true` means the boost is in
effect; if the route could not take it, the reply is `not-applied` or
`route-unavailable`.

### `apply-profile` (Waves 1.8.0)

```text
→ {"id":9,"cmd":"apply-profile","profile":"Focus"}
← {"id":9,"ok":true,"profile":{"name":"Focus","applied":3,"savedForLater":1,"skipped":0,"failed":0}}
```

`profile` is matched by name, ignoring case, exactly like `waves://apply-profile`.
Names are at most 100 characters and may not contain control characters
(`invalid-parameter`). No match is `unknown-profile`.

Waves replies after the whole profile has finished applying, which can take a few
seconds when several apps need new routes; allow at least 25 seconds. The counts
cover the profile's apps that carry levels:

- `applied`: set now (or already at those levels).
- `savedForLater`: the app is not running; its levels are saved and apply when it
  next opens.
- `skipped`: the app is excluded from Waves.
- `failed`: could not be set, or a newer change replaced it first.

`ok` is `true` only when `failed` is `0`. Otherwise the reply is `ok:false` with
`error:"not-applied"` and the same `profile` counts. If another profile was
applied before this one finished, the reply is `not-applied` without counts.
Waves also shows its usual "Profile applied" notice.

### `refresh` (Waves 1.8.0)

```text
→ {"id":10,"cmd":"refresh"}
← {"id":10,"ok":true,"apps":[…]}
```

Rescans running apps, the same as **Refresh** in Waves, and replies with the
updated `list-apps` roster once the scan has finished. If a refresh is already
running, Waves waits for that one. A scan that fails is `not-applied`.

### `subscribe`, `unsubscribe`

After `subscribe`, Waves pushes:

```text
← {"ok":true,"event":"app-changed","changed":{"id":"com.spotify.client","name":"Spotify",
   "running":true,"muted":true,"volume":0.8,"live":true,"managed":true}}
← {"ok":true,"event":"apps-changed"}
```

`app-changed` carries one app whose volume, mute or live state moved, whatever
caused it. `apps-changed` means the roster changed (an app appeared, quit or was
excluded); call `list-apps` again. A third subscription from the same process is
refused with `rate-limited`.

## Errors

| `error` | Meaning |
| --- | --- |
| `unsupported-protocol` | `hello` asked for a protocol other than 1. |
| `malformed-request` | Not valid JSON, missing `cmd`, a wrong field type, or a command before `hello`. |
| `unknown-command` | Valid request with a command this Waves does not know (1.8.0 and later). |
| `missing-parameter` | A required field is missing (or a volume is not a number). |
| `invalid-parameter` | A field is present but outside what Waves accepts (1.8.0 and later). |
| `unknown-app` | No app with that identifier in the mixer. |
| `unknown-profile` | No profile with that name (1.8.0 and later). |
| `app-excluded` | The app is excluded from Waves. |
| `route-unavailable` | Wave Link or route recovery controls this app's route, so Waves cannot change this here (1.8.0 and later). |
| `not-applied` | Waves tried and the change did not take effect (1.8.0 and later). |
| `audio-not-running` | Waves has not finished setup or its audio engine is not running. |
| `rate-limited` | Over the request budget, or too many subscriptions. |
| `not-permitted` | External control is turned off in Settings. |

A client should treat an `error` value it does not recognise as a generic failure
and show `message`.

## Compatibility rules

Protocol 1 only grows. New commands, response fields and error values may be
added; existing ones keep their names, types and meaning. Clients must ignore
response fields they do not know.
