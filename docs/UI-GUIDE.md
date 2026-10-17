# iScreen Menu UI Guide

This page walks through the menu from top to bottom. Click the menu bar icon to open the menu; click anywhere outside it or press Esc to close it. Labels are shown in English; the Chinese labels used when macOS is set to Chinese are in parentheses.

<img src="images/menu.png" alt="iScreen Menu panel" width="345">

## 1. Header and power

The left side shows "iScreenBar" and the connection status: a green dot means connected, orange means sync error (同步异常, usually the Studio Display was not detected), grey means the lamp is not connected. When the lamp is on, the status line also shows the current brightness and colour temperature.

The round button on the right turns the lamp on or off; it is blue when the lamp is on.

## 2. Brightness and colour temperature

- **Brightness (亮度)**: the longer the white fill, the brighter. 1% is the lowest the lamp goes and does not mean fully off; use the power button to turn it off.
- **Colour temperature (色温)**: warm on the left, cool on the right; the white marker shows the current value.

Changes are sent to the lamp when you release the slider. If the lamp is off, moving a slider turns it on first. The brightness slider is disabled while Auto Light is on (the lamp's sensor controls brightness); the colour slider is disabled while Auto Color is on.

## 3. Toggles

A toggle's icon is highlighted when it is on, and some toggles show a short note while on. Hover to see a full description.

| Toggle | What it does |
| --- | --- |
| Auto Light (自动感光) | The lamp's own sensor controls brightness; mutually exclusive with Follow Display |
| Auto Color (自动色温) | Gradually adjusts colour temperature by local time of day; it does not measure the room's colour temperature |
| Presence (入座检测) | The lamp turns off after you leave; set the time and sensitivity in Presence settings |
| Video Mode (视频模式) | Fill-light mode for video calls |
| Follow Display (亮度跟随) | First set the lamp and the Studio Display to comfortable levels, then turn this on to lock in the difference |
| Sleep Sync (熄屏同步) | Turns the lamp off when the Studio Display sleeps and restores it on wake |

## 4. Presence Settings (入座检测设置)

Choose the away time (3/5/10 minutes) and detection sensitivity (low/medium/high) in the submenu. While an ambient rule has turned the lamp off or the display is asleep, presence detection is paused and restored afterwards.

## 5. Ambient Light Calibration (环境光标定)

When the room feels bright enough, choose "Set Current Light as Off Point"; when you need extra light, choose "Set Current Light as On Point". Each records the Studio Display sensor value. "Turn Light On/Off by Ambient Light" reuses the saved thresholds, so you don't need to recalibrate every day. The bottom of the submenu shows the current ambient value and calibration status.

The ambient value is a filtered, relative reading from the Studio Display sensor, not a calibrated lux meter. Turning off and quick turn-on each need about 30 seconds of sustained light level; gradual turn-on takes about 45 seconds; values in between may keep the current state. Sleep Sync takes priority: a darker room cannot turn the lamp on while the display is asleep.

## 6. Light Presets (灯光预设)

Presets save brightness, colour temperature and video mode. "Mode Center…" (模式中心设置…) lets you add scenes and bind them to the frontmost app. These presets are separate from the lamp's own hardware memory.

## Menu bar icon

<img src="images/menu-bar-icon.png" alt="Menu bar icon" width="36">

The centre ring is always shown. The 8 rays light up clockwise from the top as brightness increases (about 12.5% each); all rays are faint when the lamp is off or disconnected. A small dot appears at the bottom right when there is a sync problem.

## Feedback

Behaviour can differ between firmware and macOS versions. When reporting a problem, please include the macOS version, device models, steps to reproduce and a redacted log.
