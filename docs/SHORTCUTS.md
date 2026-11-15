# Control Waves from the Shortcuts app

Waves has no Shortcuts actions of its own. You can still drive it from the
Shortcuts app in two ways:

- **Open URLs** with a `waves://` link. Good for setting a volume, muting, or
  applying a profile.
- **Run Shell Script** with `wavesctl`, the command-line client inside Waves.
  Use it when you need what a link cannot do: a relative volume change, a reply
  you can use in the next action, or a clear failure when something did not
  apply.

Everything here runs on your Mac. Nothing is sent over the network.

## Before you start

1. Open **Waves ▸ Settings ▸ Shortcuts & Automation**.
2. For `waves://` links, turn on **URL scheme automation**. While it is off,
   Waves ignores every `waves://` link without a notice.
3. For `wavesctl`, turn on **Allow external control**, and in the Shortcuts app
   turn on **Shortcuts ▸ Settings ▸ Advanced ▸ Allow Running Scripts**.
4. Keep Waves running. If Waves is not running, opening a `waves://` link starts
   it, but that first command is not carried out: Waves shows **Finish setup**
   and you run the shortcut again once Waves is ready. `wavesctl` fails with
   "Could not connect to Waves" instead.

`toggle-mute` and `set-boost` links, and the `wavesctl boost`, `profile` and
`refresh` commands, need Waves 1.8 or later.

### Find an app's ID

Commands name apps by their ID, usually the bundle identifier, such as
`com.spotify.client`. To list the IDs of the apps Waves shows, run this in
Terminal (with **Allow external control** on):

```sh
/Applications/Waves.app/Contents/Helpers/wavesctl apps
```

The first column is the ID. Profile names are matched ignoring case.

## Recipes with Open URLs

In each recipe, create a shortcut, add the **Open URLs** action, and paste the
link. Replace the app ID or profile name with your own. Spaces and other
special characters in a link must be percent-encoded: `Deep Work` becomes
`Deep%20Work`.

### Set an app's volume

```text
waves://set-volume?app=com.spotify.client&volume=0.3
```

`volume` runs from `0` to `1` (`0.3` is 30%). A value outside that range is
refused, not clamped.

### Mute and unmute

```text
waves://mute?app=com.spotify.client&muted=true
waves://mute?app=com.spotify.client&muted=false
waves://toggle-mute?app=com.spotify.client
```

### Apply a profile

```text
waves://apply-profile?name=Focus
waves://apply-profile?name=Deep%20Work
```

A link applies a profile's levels and EQ. It never moves an app to another
output device, even if the profile saved one, because anything that can open a
link could send it. To apply a profile including its outputs from a shortcut,
use `wavesctl profile` in a Run Shell Script action (below).

### Set boost

```text
waves://set-boost?app=com.spotify.client&boost=2
```

`boost` runs from `1` (off) to `4`, the same as the Boost menu in the mixer.
Anything outside that range is refused. Waves also refuses boost for an app it
is excluded from and for an app whose audio Wave Link or route recovery
controls, exactly as the mixer does.

### Refresh the app list

```text
waves://refresh
```

## Recipes with Run Shell Script

Add the **Run Shell Script** action, set **Shell** to `zsh`, and use the full path
to `wavesctl`, because Shortcuts does not use your Terminal `PATH`:

```sh
/Applications/Waves.app/Contents/Helpers/wavesctl nudge com.spotify.client -0.1
```

That turns Spotify down by 10 points, something a link cannot do. Other
commands:

```sh
W=/Applications/Waves.app/Contents/Helpers/wavesctl
$W volume com.spotify.client 0.3      # set volume, 0 to 1
$W mute com.spotify.client            # mute
$W unmute com.spotify.client          # unmute
$W toggle com.spotify.client          # toggle mute; prints the new state
$W boost com.spotify.client 2         # boost, 1 to 4
$W profile Deep Work                  # apply a profile; waits until it has applied
$W refresh                            # rescan apps; waits until done
$W apps                               # list apps; pass the output to the next action
$W help                               # every command
```

`wavesctl` waits for Waves's answer. It exits with status `0` when the change
was made, and otherwise prints the reason (for example `error: unknown-app`) and
exits with a non-zero status, which stops the shortcut with that message. A
profile reply also lists how many apps were applied, saved for later (not
running), skipped (excluded), or failed.

## A Focus that applies a profile

On macOS versions where the Shortcuts app has an **Automation** tab:

1. Open **Shortcuts ▸ Automation** and create a new automation.
2. Choose **Focus**, pick the Focus (for example **Work**), and choose
   **When Turning On**.
3. Set it to run immediately, and add **Open URLs** with
   `waves://apply-profile?name=Work`.
4. Optionally make a second automation for **When Turning Off** that applies
   another profile, such as `waves://apply-profile?name=Everyday`.

If your Shortcuts app has no Automation tab, make the same shortcut and run it
from the menu bar or with a keyboard shortcut (below).

## A keyboard shortcut

1. Create a shortcut with **Open URLs** and
   `waves://toggle-mute?app=com.spotify.client`.
2. Open the shortcut's details (the ⓘ button) and choose **Add Keyboard
   Shortcut**, then press the keys, for example ⌃⌥⌘M.

For mute and volume on the app in front, or a mute key for one app, Waves's own
shortcuts in **Settings ▸ Shortcuts & Automation** respond faster and do not need
URL automation. Use a Shortcuts keyboard shortcut for things those cannot do,
such as applying a profile.

## Limits

`waves://` links are rate limited, so a misbehaving script cannot flood Waves:

- Waves looks at no more than **30 links in any 60 seconds**. Links beyond that
  are dropped without a notice.
- Of those, at most **10 valid commands in any 60 seconds** are carried out.
  Invalid links do not use up this allowance. Beyond it Waves shows **URL command
  throttled: Too many commands. Try again shortly.**, at most once every 5
  seconds.
- A link longer than 8 KB is ignored.

These limits run on a clock that changing the system time does not affect.

`wavesctl` connects to Waves's local control socket, which allows a burst of 60
requests and then 30 per second, far above what a shortcut sends.

## When a command is refused

A refused `waves://` command never changes anything. Waves shows a notice in its
mixer window or menu bar mixer, whichever is open; if neither is open, nothing
appears. The notices are:

| You see | Why |
| --- | --- |
| Nothing | URL scheme automation is off, the 30-links limit was reached, or the link was not a `waves://` link Waves could read. |
| **Finish setup** | Waves has not finished starting, or setup is not complete. |
| **URL command blocked**: Set-volume command was invalid. | Missing app ID, or a volume that is not a number from 0 to 1. Mute, toggle-mute, set-boost and profile links have matching messages. |
| **URL command blocked**: Unknown command: … | The command name is misspelled, or needs a newer Waves. |
| **URL command blocked**: App not found: … | No app with that ID. Check `wavesctl apps`; if the app is missing, start playback in it and refresh. |
| **URL command blocked**: App is excluded from Waves. | You excluded that app in Waves. |
| **URL command blocked** with a reason about Wave Link or route recovery | Boost is not available for that app in the mixer either. |
| **Profile not found** | No profile with that name. |
| **URL command throttled** | More than 10 commands in 60 seconds. |

`wavesctl` prints the same kinds of reasons as error codes; see
[CONTROL_PROTOCOL.md](CONTROL_PROTOCOL.md#errors) for the full list.
