# Notchling

A Dynamic-Island-style notch app for macOS. It's built to work on **managed Macs**
and needs **no macOS privacy permissions**: no Accessibility, Automation, Screen
Recording, Camera, Calendars, Reminders, Notifications or Full Disk Access.

Hover over the notch to open it. On displays without a notch it shows as a pill at
the top of the screen.

## Features

| Tab | What it does | How it avoids a permission |
|---|---|---|
| **Home** | Now Playing (artwork, progress, play/pause/skip), next meeting with a **Join** button, unread Gmail count | Spotify/Music broadcast notifications + MediaRemote; Google APIs |
| **Shelf** | Drag files onto the notch to park them, drag them out later, AirDrop, Reveal in Finder | Drag-and-drop counts as user consent; only file paths are stored |
| **Clipboard** | Clipboard history (opt-in, memory-only, skips password-manager copies) | Off by default |
| **Timer** | Quick timers + Pomodoro, countdown shown next to the notch | Alerts appear in the notch with a sound, not as system notifications |
| **Prompter** | Teleprompter that scrolls right under the camera; the notch stays open while it runs | — |
| **Terminal** | Your login shell (zsh) in the notch: colors, vim/htop/less, scrollback, selection + ⌘C/⌘V, ⌘K clear, ⌘± font size. Clicking in keeps the notch open; clicking another app releases it | Built-in terminal emulator (no third-party code) on a pseudo-terminal |
| **Keep Awake** | Stay awake indefinitely or for 30m–8h, optionally keep the display on, keep Wi-Fi/network alive, and **stay awake with the lid closed** | IOKit power assertions; closed-lid mode needs an admin password (see below) |
| **Google** | Today's and tomorrow's **Calendar** events, **Gmail** unread, **Google Tasks** (add / complete) | Reads Google over HTTPS instead of the macOS Calendar/Reminders databases |

Next to the notch it also shows small live activities: an equalizer while music
plays, a timer countdown, "Meeting in 3m", and charging toasts.

### Lock-screen widgets and weather
When your Mac locks, a row of widgets appears below the clock: **weather**
(current conditions, high/low, next 5 hours), **Now Playing** with
play/pause/skip, **battery**, a running **timer**, and optionally your **next
calendar event**. Turn widgets on or off, and use **Preview**, in
Settings → Lock Screen. The weather also shows at the top of the Home tab.

- **No permissions.** Weather comes from [Open-Meteo](https://open-meteo.com)
  (free, no key). You choose the city, so Location Services is never needed.
  Until you choose one, the city is guessed from your time zone. Lock and unlock
  are detected with the system's public lock/unlock notifications.
- The widget window is placed above the lock screen with a private SkyLight API,
  the same way other notch apps do it. It's loaded dynamically: if a macOS
  update removes it, the feature turns itself off.
- Anyone who can see your locked Mac can see the widgets and use the music
  controls. The calendar widget is **off by default** for that reason.

### Keep Awake and the closed lid
- **Lid open:** uses the same power assertions as `caffeinate`, plus a
  `NetworkClientActive` assertion and a tiny HTTPS keep-alive every 45 s, so
  Wi-Fi, VPN and SSH sessions stay connected. No password or permission needed.
- **Lid closed:** macOS always sleeps when the lid closes, unless an external
  display and power are connected (clamshell mode). The only other way is
  `pmset disablesleep 1`, which needs an **administrator password**. Notchling
  asks once and starts a small root watcher that turns sleep back on
  automatically when you switch Keep Awake off, when Notchling quits or crashes,
  or when the battery drops to 15%. If your account isn't an admin on this
  managed Mac, this option won't work. Use clamshell mode instead.
- Don't put a Mac that's awake with the lid closed in a bag: it can overheat.

### Terminal notes
Commands run as you, from Notchling. A command that reads a protected folder
(e.g. `ls ~/Documents`) can trigger macOS's usual folder prompt, credited to
Notchling, just like any terminal app. Nothing is asked for up front.

Left out on purpose, because each one needs a permission an admin can block: camera
mirror, replacing the volume/brightness HUD, and Bluetooth device alerts.

### A note on Now Playing
Since macOS 15.4, Apple only gives full "Now Playing" info to its own apps.
By default Notchling shows **Spotify** and **Apple Music**, which broadcast their
state to every app. On older macOS versions, any player shows up.

**Optional:** Settings → General → *Show Now Playing from any app*. This
runs a small bundled helper (`Bridge/MediaBridge.m`) inside the built-in
`/usr/bin/perl`, which macOS still answers. It's off by default because it's an
unofficial technique: it can break after macOS updates, and your organization's
IT policy may not allow it.

## Build & install

Only the Xcode **Command Line Tools** are needed (`xcode-select --install`), not full
Xcode and not admin rights.

```bash
./scripts/build-app.sh --install   # builds, copies to ~/Applications, launches
```

Or just `./scripts/build-app.sh` and open `build/Notchling.app`. The app is ad-hoc
signed. Builds made on your own Mac aren't quarantined, so Gatekeeper lets them run.

Settings are in the notch's ⚙︎ button or the menu-bar icon.

## Google setup (one time, about 5 minutes)

Notchling doesn't ship a shared Google client, so your data only goes between your
Mac and Google.

1. Go to <https://console.cloud.google.com/>, then create or pick a project.
2. **APIs & Services → Library**: enable **Google Calendar API**, **Gmail API**, **Google Tasks API**.
3. **OAuth consent screen**: pick *External*, or *Internal* if you're on Google
   Workspace and allowed to. Add your address as a **test user**.
4. **Credentials → Create credentials → OAuth client ID → Application type: Desktop app**.
5. Paste the client ID and secret into Notchling → Settings → Google, then click
   **Sign in with Google**.

Sign-in happens in your normal browser (it works with SSO and 2FA), using
OAuth + PKCE with a `127.0.0.1` redirect. The refresh token is kept in your login
Keychain.

Scopes: `calendar.readonly`, `gmail.readonly` (optional), `tasks` (optional),
plus `openid email`.

> If your Google account is managed by an organization, the Workspace admin may
> block third-party OAuth apps. Notchling will show Google's error message if so.

## Project layout

```
Sources/Notchling/
  App/        entry point, AppDelegate, Settings window
  Notch/      notch panel, shape, hover logic, all tab views
  Features/   media, battery, shelf, clipboard, timer, teleprompter, keep-awake
  Terminal/   PTY session, xterm-compatible emulator, terminal view
  Google/     OAuth (PKCE + loopback) and Calendar/Gmail/Tasks client
  Support/    settings, Keychain
Bridge/MediaBridge.m   optional Now Playing helper (off by default)
scripts/build-app.sh
```
