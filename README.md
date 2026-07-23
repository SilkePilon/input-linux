<h1 align="center">
  <br>
  <a href="https://github.com/SilkePilon/input-linux"><img src=".github/media/input-header.png" alt="Input for Linux" width="900"></a>
  <br>
</h1>

<p align="center">
  <a href="https://github.com/SilkePilon/input-linux/actions/workflows/build-appimage.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/SilkePilon/input-linux/build-appimage.yml?branch=main&style=flat-square&label=build"></a>
  <a href="https://github.com/SilkePilon/input-linux/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/SilkePilon/input-linux?style=flat-square&label=release"></a>
  <a href="https://github.com/SilkePilon/input-linux/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/SilkePilon/input-linux/total?style=flat-square"></a>
  <img alt="Platform" src="https://img.shields.io/badge/platform-Linux%20x86__64-informational?style=flat-square">
  <img alt="Format" src="https://img.shields.io/badge/format-AppImage-orange?style=flat-square">
</p>

<p align="center">
  <a href="#install">Install</a> |
  <a href="#updates">Updates</a> |
  <a href="#whats-changed-from-the-official-app">What's changed</a> |
  <a href="#device-permissions">Device permissions</a> |
  <a href="#troubleshooting">Troubleshooting</a> |
  <a href="#build-it-yourself">Build it yourself</a> |
  <a href="#how-it-works">How it works</a>
</p>

Work Louder's **Input** app configures their keyboards and macropads, but it only
ships for Windows and macOS. This project repackages the official Windows release
as a Linux **AppImage** with the fixes it needs to actually run, and rebuilds it
whenever Work Louder puts out a new version.

> [!WARNING]
> This is an **unofficial, community-developed** port. It has been acknowledged and
> welcomed by Work Louder Inc., but it is **not officially supported or maintained
> by them**, and functionality and stability are not guaranteed.
>
> The software is provided **"as is"**, without warranties of any kind. Use it at
> your own risk. Work Louder does not guarantee the safety, integrity or reliability
> of anything downloaded from this repository, and cannot be held liable for any
> damages or legal claims arising from its use or distribution. You are responsible
> for reviewing the software before installing it. By using, copying, modifying or
> distributing it, you agree to these terms.

## Install

Grab the latest `.AppImage` from the
[Releases page](https://github.com/SilkePilon/input-linux/releases/latest).

The easiest way to use it is [AppManager](https://github.com/kem-a/AppManager).
Drag the file in and it handles the rest: desktop entry, icon, background updates,
and clean removal later. It also runs AppImages without FUSE installed, which saves
you the most common bit of setup. [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever)
does much the same job if you already have it.

To just run the file directly:

```bash
chmod +x Input-*.AppImage
./Input-*.AppImage
```

Most distributions need FUSE for that:

```bash
sudo apt install libfuse2
```

## Updates

Two different things get called "updates" here. They work independently.

| | What it does | How often |
| --- | --- | --- |
| **New Input versions** | When Work Louder publishes a new version of Input, a new AppImage is built and released here automatically. | Checked daily |
| **Your installed app** | The AppImage checks this repository on launch and can update itself, the same way it does on Windows. | On launch |

Releases come in two flavours, matching what Work Louder publishes upstream:

- **Stable**: normal releases. This is what the Releases page gives you by default,
  and what most people want.
- **Pre-release**: built from upstream release candidates (`-rc`) and marked as
  pre-releases on GitHub. Newer features, rougher edges. They never show up as
  "latest", so you only get one by deliberately picking it.

Every release is built from the official Windows installer for that exact version,
then started and checked before it goes out. If the app fails to launch, no release
is created.

## What's changed from the official app

This is Work Louder's own app, repackaged. It isn't a reimplementation and it isn't
rebuilt from source. The build downloads the official Windows installer straight
from [Work Louder's release page](https://github.com/worklouder/input-releases/releases),
unpacks the Electron app inside it, and changes as little as possible to make it
run on Linux.

For the 0.17.2 build:

- **All 41 files of the app's compiled interface are byte-for-byte identical** to
  the official release. The only interface file touched is `index.html`, which gets
  a `<style>` and a `<script>` appended for the Linux window chrome and the udev
  prompt.
- The main process file grows by **547 bytes**. That is everything in the table
  below.
- Nothing else is rewritten. The rest is added alongside.

### What is changed, and why

| Change | Why |
| --- | --- |
| `--no-sandbox` when launched from an AppImage | AppImages ship no setuid `chrome-sandbox` helper, so Chromium's sandbox cannot start and the app refuses to launch. |
| Preload scripts renamed `.mjs` → `.cjs` | Sandboxed preloads are evaluated as CommonJS, so an ESM preload never runs. No IPC channel reaches the interface and you get a blank window. |
| Tray icon uses the bundled PNG instead of the `.ico` | Electron on Linux cannot decode a Windows `.ico`, and the resulting error silently cancels the rest of app startup. |
| `edge.js` tolerates a missing .NET runtime | Parts of Input are written in C#. Without this the app dies on launch on any machine without .NET 8, instead of just disabling those features. |
| Frameless window, with the menu moved into a hamburger | Upstream builds a macOS-shaped menu bar. Linux draws it as a GTK strip inside the window, stacking three bars on top of each other. |
| A udev permission prompt is added | Linux needs a udev rule to reach USB HID devices. Windows and macOS don't. |
| The in-app update check points here instead of upstream | **This one is a real behavioural change.** Left alone, Input would check Work Louder's feed and offer you a Windows installer. It now checks this repository's releases, so "update" gets you a newer AppImage. |

Nothing is added that phones home, and no telemetry or analytics behaviour is
touched. Input's own privacy prompt still governs that exactly as it does on
Windows. Nothing is fetched at runtime either, since the udev installer runs from a
copy inside the AppImage.

### Check for yourself

Please do. The patches are one readable file,
[`scripts/patch-app.py`](scripts/patch-app.py), and everything injected lives in
[`patch/`](patch/). None of it is hidden in a binary blob.

To see the exact difference against the official app, build it and diff the two:

```bash
KEEP_BUILD_DIRS=true ./build-appimage.sh
asar extract input_rebuild/app-64/resources/app.asar /tmp/input-official
diff -r /tmp/input-official/dist-electron input_work/app/dist-electron
```

Every build also prints each patch as it is applied, and refuses to produce an
AppImage if any of them no longer matches.

## Device permissions

Linux needs a udev rule before a non-root program can talk to your keyboard, so the
first time you launch Input it shows a **Device Setup Required** prompt.

Press **Install now** and approve the system password dialog. The installer ships
inside the AppImage, so nothing is downloaded, and the prompt goes away by itself
once the rules exist. Then **unplug and replug your keyboard**.

The prompt only appears when the rules are genuinely missing. If it comes back
later, something removed them.

<details>
<summary><strong>Installing them by hand instead</strong></summary>

**Copy command** in the prompt puts a ready-to-paste command on your clipboard that
runs the bundled installer. Or fetch it yourself:

```bash
curl -sSL https://raw.githubusercontent.com/SilkePilon/input-linux/main/patch/dist-electron/scripts/install-udev-worklouder.sh | sudo bash
```

To remove the rules again:

```bash
curl -sSL https://raw.githubusercontent.com/SilkePilon/input-linux/main/patch/dist-electron/scripts/install-udev-worklouder.sh | sudo bash -s uninstall
```

The rules land in `/etc/udev/rules.d/99-worklouder.rules` and grant access to
Work Louder (`303a`) and Nomad (`574c`) devices.

</details>

## Troubleshooting

<details>
<summary><strong>The app doesn't detect my device</strong></summary>

Almost always the udev rules. See [Device permissions](#device-permissions).
Remember to replug the keyboard afterwards, since the rules are applied when the
device is connected.

</details>

<details>
<summary><strong>The AppImage won't start at all</strong></summary>

Most distributions need FUSE 2 (`sudo apt install libfuse2`, or your distribution's
equivalent). To rule FUSE out entirely, run it extracted:

```bash
./Input-*.AppImage --appimage-extract-and-run
```

Installing through [AppManager](https://github.com/kem-a/AppManager) avoids the
problem, since it doesn't rely on FUSE.

</details>

<details>
<summary><strong>Some features silently do nothing</strong></summary>

Parts of Input are written in C# and need the .NET 8 runtime. The AppImage starts
fine without it, and those features are disabled rather than taking the app down.
Install `dotnet-runtime-8.0` from your distribution to switch them on.

</details>

<details>
<summary><strong>It opens to a blank window</strong></summary>

That shouldn't happen, since every release is startup-tested for exactly this.
Please [open an issue](https://github.com/SilkePilon/input-linux/issues) with your
distribution and the output of running the AppImage from a terminal.

</details>

## Build it yourself

You don't need to, since releases are automatic, but the whole thing is one script.

### Requirements

| Tool | Purpose | Debian/Ubuntu |
| --- | --- | --- |
| `curl` | Download files | `sudo apt install curl` |
| `7z` | Extract the `.exe` and `.7z` archives | `sudo apt install p7zip-full` |
| `node` + `npm` | JavaScript runtime and package manager | `sudo apt install nodejs npm` |
| `asar` | Unpack and repack Electron archives | `sudo npm install -g asar` |
| `build-essential` | Compile native modules | `sudo apt install build-essential` |
| `python3` | node-gyp and the patch scripts | `sudo apt install python3 python3-venv` |
| .NET 8 SDK | Compiles the `electron-edge-js` C# bootstrap | see below |

```bash
sudo apt update
sudo apt install curl p7zip-full nodejs npm build-essential python3 python3-venv git
sudo npm install -g asar
curl -sSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 8.0
```

The .NET install above needs no root, and the build script picks it up from
`~/.dotnet` automatically.

### Running it

```bash
git clone https://github.com/SilkePilon/input-linux.git
cd input-linux
./build-appimage.sh
```

That resolves the latest stable Input release, downloads that version's official
Windows installer, rebuilds the native modules for Linux, applies the patches,
packages an AppImage and starts it to check the result.

| Variable | Default | Effect |
| --- | --- | --- |
| `VERSION` | latest stable upstream | Build a specific Input version |
| `CHANNEL` | `stable` | `prerelease` builds the newest `-rc` instead |
| `ELECTRON_VERSION` | auto-detected | Override the Electron version to build against |
| `SKIP_SMOKE_TEST` | `false` | Skip the post-build startup verification |
| `KEEP_BUILD_DIRS` | `false` | Keep the `input_*` working directories |
| `TEST_MODE` | `false` | Continue past non-critical errors |
| `RELEASE_REPO` | `$GITHUB_REPOSITORY` | Repository the app's update check points at |

```bash
VERSION=0.17.2 ./build-appimage.sh
CHANNEL=prerelease ./build-appimage.sh
```

## How it works

[What's changed from the official app](#whats-changed-from-the-official-app) lists
the patches themselves. This is how they get applied.

Every patch lives in `scripts/patch-app.py`. They target a minified bundle produced
by a build nobody here controls, so each one matches on a regex that tolerates
changed whitespace and renamed local variables rather than on a fixed string. Each
is idempotent, and each is **required**: if one stops matching a future Input
version, the build fails loudly instead of shipping an AppImage that opens to a
blank window. That is deliberate. This port has previously shipped releases where a
patch silently did nothing.

The interface is modified by injecting `patch/dist/index-{head,body}-*.html`
fragments into the app's own `index.html` rather than shipping a replacement copy of
it. Each Input version references its own content-hashed asset bundles, so a static
copy would break every version except the one it came from.

### The window chrome

On Linux the window is created with `frame: false`, so the app's own black header
*is* the top of the window. The GTK menu bar is hidden with `autoHideMenuBar`, which
keeps every accelerator registered. Undo/Redo, cut/copy/paste and the zoom shortcuts
all still work, and <kbd>Alt</kbd> reveals the bar.

The commands that used to live in that bar (including **Download Logs**) show up as
a hamburger dropdown in the header instead. It isn't a reimplementation of the menu.
`linux-app-menu.js` reads `Menu.getApplicationMenu()` when the dropdown opens and
serialises it, tagging each entry with the index path used to find the real
`MenuItem` again on click. Whatever upstream puts in its menu appears automatically.

Minimise, maximise and close are HTML, styled from the app's own palette: `#eeff01`
accent, `#ff0004` red, 10px corners, 2px round-capped strokes. The window corners
are rounded in CSS, which needs `transparent: true`, because an undecorated window
gets no rounding from the compositor and the root element's background would
otherwise paint across the whole canvas.

| File | Role |
| --- | --- |
| `patch/dist/index-head-titlebar.html` | Drag region, button and dropdown styling, rounded corners |
| `patch/dist/index-body-window-controls.html` | Injects the buttons and dropdown, re-mounts them when React replaces the header |
| `patch/dist-electron/preload/window-controls-preload.cjs` | `window.inputLinuxWindow` bridge, appended to the app's own preload |
| `patch/dist-electron/main/linux-window-controls.js` | Performs the window operations |
| `patch/dist-electron/main/linux-app-menu.js` | Serialises the real application menu and runs what's clicked |

### Smoke test

Every build ships a dormant harness that `INPUT_SMOKE_TEST=1` activates. It waits
for the main window, verifies the interface mounted and the preload's globals
arrived, opens the hamburger and measures it, checks the window chrome, watches for
main-process unhandled rejections, and captures a screenshot.

```bash
./scripts/smoke-test.sh                 # newest Input-*.AppImage here
./scripts/smoke-test.sh path/to.AppImage
```

It runs at the end of every build and in CI, using `xvfb-run` on headless machines.
A release is never published if it fails.

## Contributing

Pull requests are welcome. This is maintained on a best-effort basis by the
community. If a patch stops applying after an upstream release, the build output
names the one that failed, and the fix goes in `scripts/patch-app.py`.

## License

This project does not claim ownership of Input. Input is a product of Work Louder
Inc. This port is provided under an unofficial and permissive approach intended to
help Linux users make use of their devices. Refer to the individual license files,
if applicable.

<p align="center">
  <a href="https://github.com/SilkePilon/input-linux/releases">Releases</a> |
  <a href="https://github.com/SilkePilon/input-linux/issues">Issues</a> |
  <a href="https://github.com/worklouder/input-releases/releases">Upstream releases</a> |
  <a href="https://worklouder.cc">Work Louder</a>
</p>
