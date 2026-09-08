# Using Waves with Wave Link

Waves controls app volume and mute through Wave Link 3 while Wave Link handles
the audio mix. Boost, EQ, effects, and output routing stay in Wave Link.
Older Wave Link control protocols are not supported; use Wave Link itself to
adjust apps if you cannot use Wave Link 3.

## Set up independent app control

1. Open Wave Link 3 and Waves.
2. In Waves, open Settings > Mixer. Leave Wave Link compatibility on and choose
   Waves as the per-app controller.
3. In Wave Link, give each app you want to control independently its own software
   channel. Choose Create channel and select the app. Apps already grouped on
   another channel appear under Transfer from other channel.
4. Add the new channel to the mix you listen to. Check the mix's output device,
   level, and mute state. An empty channel without a mix cannot carry sound.
5. In Waves, choose Test Connection. Play sound in the app so it appears in the
   mixer, then adjust its volume or mute.

For example, if Zoom and Slack share a Voice Apps channel, create a separate
Zoom channel and add it to your listening mix. Zoom and Slack can then have
independent levels.

Waves can move an app to an available software channel after a manual level
change only when both channels have the same mix assignments, per-mix levels,
and mute settings. If that information is missing or different, Waves leaves
the app in place and asks you to configure a dedicated channel manually.
Automated commands do not move apps between channels.

## If something goes wrong

| What you see | What to do |
| --- | --- |
| Wave Link needs attention or the connection test fails | Open Wave Link 3 and test again. If it still fails, restart Wave Link and Waves. Use current versions of both apps. |
| Invalid params from an older Waves build | Update Waves to 1.7.2, which corrects parameterless requests, then test again. |
| The app needs its own channel | In Wave Link, choose Create channel, select the app, and add its new channel to your listening mix. Retry the control in Waves. |
| A channel is not added to a mix | Add that channel to the mix you listen to and check the mix's output device. Retry in Waves. |
| Connected, but silent | Check the app is playing sound, its channel is in the intended mix, channel and mix levels are above zero, both are unmuted, and the mix has the intended output device. |
| Volume changes another app too | The apps share a Wave Link channel. Separate them before controlling their levels independently. |
| Waves says the Wave Link process is not verified | Use the official Elgato Wave Link installation. Do not disable compatibility as a workaround. |
| Controls are owned by Wave Link | Choose Waves as the per-app controller in Settings > Mixer, or adjust the app in Wave Link. |

A successful connection test verifies the control connection and reads the
channel list. It does not verify that sound reaches headphones, speakers, or a
stream. Leave compatibility enabled while troubleshooting to avoid duplicate
audio paths.

If the problem continues, open Settings > Diagnostics and choose Copy Diagnostics.
Include the Waves version, Wave Link version, affected app, and the action that
failed when asking for support. Review the report before sharing it.
