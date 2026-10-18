# iScreen Menu Feature List

> Reflects the version currently installed from the `main` branch. This is an unofficial macOS menu bar tool that runs locally.

## 1. Menu Bar and Runtime Status

- Click the menu bar icon to open the system menu: the lighting panel is at the top, followed by native submenus and "Quit" (⌘Q).
- Monochrome icon: the central ring is always lit, and the 8 rays around it light up according to brightness; the rays fade when the lamp is off or disconnected.
- When the USB connection, Studio Display detection or the lamp power command fails, a small dot appears at the bottom right of the icon and the top of the panel shows "Sync error (同步异常)".
- Hovering over the icon shows the current brightness and colour temperature of the iScreenBar.
- The lamp state is read actively when the menu is opened; synchronisation and state read-back continue while the menu is expanded.
- Runs automatically after login through a user-level LaunchAgent, with no administrator privileges required; after quitting from the menu it stays quit, and it restarts automatically only after an abnormal exit.

## 2. Basic iScreenBar Control

- **Lamp switch**: the round button at the top right of the panel turns the iScreenBar on or off directly.
- **Brightness adjustment**: 1%--100%, adjustable with the slider in the panel.
- **Colour temperature adjustment**: 2700K--6500K, adjustable in 100K steps.
- **State read-back**: reads the power, brightness, main light/back light colour temperature, auto light, presence detection and video mode states.
- **Manual operation compatibility**: after a physical button on the lamp changes its state, the tool reads the state again and refreshes the interface.
- **Adjusting while the lamp is off**: dragging brightness/colour temperature, toggling Auto Light (自动感光) or applying a preset turns the lamp on first and writes the value after about 0.5 seconds; adjustments of the same kind made during the wait keep only the latest one. This does not turn the lamp on while an ambient light rule has switched it off.

## 3. Studio Display Sleep Sync (熄屏同步)

- When the Studio Display turns off its screen or goes to sleep, the iScreenBar is turned off automatically.
- When the Studio Display wakes, the lamp is turned back on automatically if it was turned off by this tool.
- While the screen is off, power synchronisation has the highest priority: lamp auto light, presence detection or any other logic must not turn the lamp back on.
- The "Sleep Sync" toggle turns this feature on or off independently.

## 4. iScreenBar Brightness Follows Studio Display

- When Follow Display (亮度跟随) is turned on, the current brightness difference between the iScreenBar and the Studio Display is recorded.
- After that, when the Studio Display brightness is adjusted, the iScreenBar changes by the same fixed difference.
- The iScreenBar minimum brightness limit of 1% is preserved.
- After it is turned off, the lamp keeps its current brightness and does not return to an old value.
- Lamp auto light and this feature are mutually exclusive: turning one on turns the other off automatically, so that two brightness sources never control the lamp at the same time.

## 5. Lamp Auto Light

- The iScreenBar's built-in ambient light sensor can be turned on or off from the menu panel.
- When on, the lamp's official auto light state is used; when off, the current manual brightness is written to exit auto mode.
- The interface shows the actual state read back from the lamp, including a brief transition while the command is confirmed.
- Known lamp firmware behaviour: the physical auto light button can enter or recalibrate auto mode, but may not exit it reliably; the menu panel can run a verifiable turn-off procedure.

## 6. Studio Display Ambient Light Calibration (环境光标定) and Automatic On/Off

- Reads the Studio Display ambient light sensor directly; the lamp's sensor is not used as the data source for this set of rules.
- Uses the median of the samples from the last 10 seconds as the "ambient response score" to reduce momentary light fluctuations.
- **Bright turn-off point**: the current value is captured when clicked; the lamp is turned off after the value stays above it for 30 seconds.
- **Dim turn-on point**: the current value is captured when clicked; the lamp is turned on after the value stays below it for about 30 seconds.
- After an ambient turn-off there is also a gradual turn-back-on path of about 45 seconds that tolerates small fluctuations, to avoid repeated flickering or the lamp staying off for too long.
- The two calibration points can exist separately; setting both is not required.
- A calibration button lights up briefly only when capture succeeds, and the saved value stays beside it.
- A separate enable switch decides whether the saved thresholds are applied; turning it off does not delete the calibrated values.
- If the turn-on point is higher than or equal to the turn-off point, the interface warns of a threshold overlap risk.
- Once the ambient turn-off lock is engaged, lamp auto light and presence detection cannot turn the lamp back on.
- If presence detection was on before the lamp was turned off, it is paused temporarily and resumes automatically after the ambient turn-off lock is released.
- Sleep Sync has higher priority than the ambient light rules: when the screen is off, the lamp does not turn on even if the environment becomes dim.

## 7. Presence / Away Detection

- Lamp presence detection (入座检测) can be turned on or off in the panel.
- Away time supports 3, 5 and 10 minutes.
- Detection sensitivity supports three levels: low, medium and high.
- Settings are sent to the lamp directly when it supports them; if sending fails, the local choice is kept and a log entry is written.
- Works together with the ambient turn-off lock to avoid "the lamp turning back on when the person moves after it was turned off".

## 8. Video Mode

- The iScreenBar Video Mode (视频模式) can be turned on or off from the panel.
- The video mode state is read back from the lamp and can be saved as part of a lighting mode preset.

## 9. Auto Colour Temperature

- "Auto Color (自动色温)" adjusts the lamp colour temperature smoothly according to the time of day.
- 00:00--06:00: 3000K.
- 06:00--10:00: gradual transition from 3000K to 5500K.
- 10:00--16:00: 5500K.
- 16:00--21:00: gradual transition from 5500K to 3500K.
- 21:00--24:00: gradual transition from 3500K to 3000K.
- Uses 50K as the internal transition step and writes to the lamp at most once per minute.
- No colour temperature is written while the lamp is off or the Studio Display screen is off.
- After auto colour temperature is turned off, the current colour temperature is kept.
- "Auto Tone (自动色调)" instead matches the lamp to the Studio Display's current white point, read from the private CoreBrightness framework. It follows True Tone and Night Shift; with both off it follows the display's native white (about 6500K).
- Auto Tone checks the white point every 5 seconds and writes when it moves at least 75K, rounded to 100K.
- Only one of Auto Color and Auto Tone can be on. Choosing a preset turns them off; an app-bound mode pauses them while that app is in front.

## 10. Lighting Mode Presets

- Built-in "My Favorite (我的最爱)" default: 47% / 5500K / video mode off.
- Built-in "Night Work (夜间工作)": 30% / 4000K / video mode off.
- Built-in "Wind Down (睡前放松)": 20% / 3000K / video mode off.
- The current brightness, colour temperature and video mode can be saved as a custom scene.
- The "Mode Center (模式中心)" lists the available modes and supports quick application.
- Applying a preset automatically turns the lamp on, writes brightness and colour temperature, sets the video mode, and turns off iScreenBar brightness follow.
- The current lighting mode can be bound to a specific macOS app; when the foreground app changes, the corresponding mode is applied automatically.

## 11. Philips Hue Sync

- The "Hue Lights…" menu item opens a window that stays on top. It finds a Hue Bridge on the local network over Bonjour and pairs after the bridge's link button is pressed.
- The window lists the bridge's lights grouped by Hue room. Lights with colour temperature and dimmable white lights can be selected; each row shows whether the light is on, off or unreachable.
- Options: Color Temperature (on by default) and Brightness (off by default). Brightness uses a "Hue level" from 25% to 300% of the lamp's brightness, capped at 100%.
- The "Hue Sync" toggle in the menu turns syncing on or off without losing the selection; before pairing it opens the Hue window.
- Updates are throttled to one batch every 0.3 seconds and are confirmed per light. Lights that reject an update (usually because they are off) are retried after the light list is refreshed, every 30 seconds until they accept it.
- All bridge connections bypass the system proxy. The bridge certificate must match the bridge ID. See [Security](../SECURITY.md).

## 12. USB Disconnection, Reconnection and Fault Tolerance

- The iScreenBar USB HID connection is checked every 2 seconds.
- When the lamp is unplugged, loses power or HID commands stop working, the icon shows the error dot and a log entry is written.
- After the lamp is plugged back in, the HID Manager is rebuilt, the state is read again, and the sleep sync and brightness follow locks are restored.
- When the Studio Display is disconnected the program stays resident, and after it reconnects the display listener and the ambient light sensor connection are rebuilt automatically.
- All key states and errors are written to `~/Library/Logs/iScreenBarStudioSync.log`.

## 13. Interface and Interaction

- Native AppKit system menu, no Dock icon required, adapts automatically to light/dark mode.
- Two-column toggle cards: the round SF Symbols icon uses the accent colour when on, and some toggles show a short description when on.
- The brightness slider has a white fill; the colour temperature slider is a warm-to-cool gradient with a white marker; clicking anywhere on the track jumps to that position, and the lamp follows while dragging (at most every 50 ms); the exact value is written on release.
- The brightness slider is greyed out when auto light is on, and the colour temperature slider is greyed out when Auto Color or Auto Tone is on; related controls are greyed out when the lamp is offline.

## 14. Local Storage, Privacy and Installation

- All switches, thresholds, presets and app bindings are stored in the local `UserDefaults`.
- No account, cloud service or analytics is required. The only network access is the optional Philips Hue sync with a Hue Bridge on the local network.
- The Hue API key, bridge address and bridge ID are stored in the local `UserDefaults`.
- The install script compiles locally, signs ad hoc, installs to `~/Applications`, and creates a user-level LaunchAgent.
- The uninstall script stops the service and moves the installed app and the LaunchAgent to the Trash; the log is kept by default for troubleshooting.

## 15. Implementation Limits and Risk Notes

- Verified on an Apple Silicon Mac, macOS 26, Apple Studio Display and BenQ iScreenBar `VID 0x04A5 / PID 0x2501`.
- iScreenBar control uses a device-specific 33-byte HID report; compatibility with other models is not guaranteed.
- Studio Display brightness reading uses the private macOS DisplayServices interface, which needs regression testing on real hardware after system upgrades.
- The Studio Display is identified by Apple vendor ID 0x0610 and product IDs 0xAE46 / 0xAE3A; models not listed are identified by the display name "Studio Display".
- Some details of lamp auto light and presence detection depend on the lamp firmware version.

## 16. Feature Priority

1. Studio Display sleep sync: the lamp stays off while the screen is off.
2. Studio Display ambient turn-off lock: once the bright threshold is reached, presence detection, auto light and manual adjustment are prevented from turning the lamp back on.
3. Lamp auto light and iScreenBar brightness follow are mutually exclusive.

## 17. Differences from the Official BenQ iScreenBar App

> The comparison is based on the official BenQ iScreenBar product page, quick start guide and public feature descriptions. The official app is updated by region and version; the comparison below is based on public material as of August 2026 and the official app on this machine.

### 17.1 Features Both Have

| Feature | Official BenQ App | This tool | Main difference |
| --- | --- | --- | --- |
| Lamp switch | Supported | Supported | This tool adds USB offline error indication and reconnection recovery. |
| Brightness and colour temperature | Supported | Supported | The official app advertises stepless 0--100% brightness and 2700K--6500K; this tool writes the steps that can be verified over the lamp's HID interface. |
| Auto light | Supported | Supported | Both use the lamp's ambient light sensor; this tool additionally handles mutual exclusion with brightness follow. |
| Presence detection | Supported | Supported | The official app uses a 24GHz millimetre-wave sensor and allows the detection range to be adjusted; this tool provides away time and sensitivity controls. |
| Video mode | Supported | Supported | The official app can enable it automatically together with the iMac camera; this tool currently relies mainly on a manual switch and mode presets. |
| Lighting modes | Supported | Supported | Both can save combinations of brightness, colour temperature and so on. |
| Per-app mode binding | Supported | Supported | Both can apply the corresponding lighting mode when the foreground app changes. |
| Turn lamp on/off with the display | Supported | Supported | The official app targets compatible iMacs; this tool fills in the standalone Studio Display screen-off scenario. |

### 17.2 Features This Tool Adds over the Official App

- **Dedicated Studio Display support**: the officially published compatibility range is 2021 and later iMacs and does not include the Apple Studio Display; this tool specifically listens for Studio Display sleep, screen-off, wake and disconnect/reconnect.
- **Studio Display brightness linked to the lamp**: keeps the brightness difference between the lamp and the display, and changes the iScreenBar in step when the Studio Display is adjusted.
- **Studio Display ambient light threshold control**: the "bright turn-off point" and "dim turn-on point" can be captured separately, and the lamp is turned on and off automatically using the median, duration and priority rules.
- **Auto colour temperature**: changes smoothly between 3000K--5500K according to the time of day, rather than relying only on manual steps or fixed modes.
- **Visible health status**: the menu bar icon shows brightness by the number of rays, shows an indicator dot on errors, and shows brightness and colour temperature on hover.
- **Clearer rule priorities**: there are explicit mutual exclusion and recovery rules among sleep, ambient turn-off, presence detection, auto light and brightness follow.
- **USB fault tolerance and logging**: the HID Manager is rebuilt automatically after the lamp is unplugged and replugged, and a local log is kept for troubleshooting.
- **Local and auditable**: configuration is stored only on this machine, with no account, cloud or analytics; the source code is public under the MIT licence.

### 17.3 Where the Official App Currently Has the Advantage

- **Official signing, release and firmware support**: the official app is maintained by BenQ and has formal support for firmware upgrades, regional versions and lamp protocol changes.
- **Native iMac compatibility**: the official app is designed around the hardware, power supply, camera and wake flow of 2021 and later iMacs, so its compatibility boundary is clearer.
- **Automatic video mode from the camera**: official material states that camera mode can be activated automatically when connected through the iMac USB-C port; this tool does not yet implement reliable detection of camera use.
- **Official lamp memory semantics**: the "My Favourite / memory" stored on the lamp itself is managed by the firmware; this tool's mode presets are mainly stored in the Mac's `UserDefaults`, which is not the same kind of hardware memory.
- **Polish and support channels**: the official app has more complete onboarding, upgrades, signing, notarisation, customer service and warranty support.
- **Lower risk on system upgrades**: this tool reads Studio Display brightness through a private macOS interface and must be re-verified after system upgrades.

### 17.4 Not Yet Fully Aligned or Still to Be Verified

- Automatically switching video mode when the camera is enabled.
- The protocol the official app uses to read, overwrite and recall the lamp's hardware "My Favourite" memory.
- All time steps of the official presence detection and the sensitivity mapping across firmware versions.
- The exact behaviour of official mode binding when apps quit, in full screen, across multiple Spaces and in multi-user sessions.
- Developer ID signing, notarisation, automatic updates and a one-click install experience for ordinary users.

### 17.5 One-Sentence Positioning

**The official app is complete first-party control software for compatible iMacs; this tool keeps the main lamp control capabilities and adds sleep sync, brightness linkage, ambient light rules and fault recovery for the Studio Display.**

### 17.6 Official References

- [BenQ iScreenBar official product page](https://www.benq.com/en-us/lighting/monitor-light/iscreenbar.html)
- [BenQ iScreenBar quick start guide](https://www.benq.com/en-us/qsg/iscreenbar/guide.html)
- [BenQ iScreenBar specifications and compatible models](https://www.benq.com/en-us/lighting/monitor-light/iscreenbar/spec.html)
