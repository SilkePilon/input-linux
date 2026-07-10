# Input - Linux Version

## ⚠️ Disclaimer

This project is an **unofficial community-developed** port of the Input application, intended for use on Linux systems.

While this project has been acknowledged and welcomed by Work Louder Inc., it is **not officially supported** or maintained by them. As such, functionality and stability are not guaranteed.

### Important Notes

- This software is provided **"as is"**, without any warranties, express or implied.
- Use at your own risk.
- **Work Louder does not guarantee the safety, integrity, or reliability of any files downloaded from this repository or related sources.** Users are responsible for reviewing and validating the software before installation.
- Work Louder cannot be held liable for any damages or legal claims resulting from the use or distribution of this software.

By using, copying, modifying, or distributing this software, **you agree to these terms**.

---

## Usage

You have two options for using Input on Linux:

### Option 1: Download Prebuilt AppImage

The easiest way to get started is by visiting the [Releases Page](https://github.com/worklouder/input-linux/releases) and downloading the latest `.AppImage`.

Make the AppImage executable and run it:

We recommend using a tool like [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever)

You may need FUSE in order for the AppImage to run.

```bash
sudo apt install libfuse2
chmod +x Input-*.AppImage
./Input-*.AppImage
```

---

### Option 2: Build It Yourself

This option rebuilds the application from the official Windows installer and packages it as a native Linux AppImage.

### Requirements

Before running the build script, ensure the following tools are installed and accessible in your `$PATH`:

| Tool             | Purpose                                          | Ubuntu/Debian Install Command                         |
|------------------|---------------------------------------------------|--------------------------------------------------------|
| `curl`           | Download files over HTTP(S)                       | `sudo apt install curl`                               |
| `7z`             | Extract `.exe` and `.7z` archives (`p7zip-full`)  | `sudo apt install p7zip-full`                         |
| `node`           | JavaScript runtime                                | `sudo apt install nodejs`                             |
| `npm`            | Node.js package manager                           | `sudo apt install npm`                                |
| `asar`           | Extract and repack `.asar` Electron archives      | `sudo npm install -g asar`                            |
| `build-essential`| Required for compiling native modules             | `sudo apt install build-essential`                    |
| `python3.11`     | Compatible Python version with venv support       | `sudo apt install python3.11 python3.11-venv`         |
| `git`            | Used to clone the repository (optional)           | `sudo apt install git`                                |

Install them all in one step:

```bash
sudo apt update
sudo apt install curl p7zip-full nodejs npm build-essential python3.11 python3.11-venv git
sudo npm install -g asar
```

---

### 🛠️ Build Process

The build script:

- Downloads the official `input-Setup-0.15.3.exe` Windows installer
- Extracts the app and auto-detects the bundled Electron version
- Rebuilds native modules (`node-hid`, `serialport`, etc.) for Linux
- Injects Linux-specific patches
- Packages everything into a standalone `.AppImage` using `electron-builder`

Run it:

```bash
git clone https://github.com/worklouder/input-linux.git
cd input-linux
bash input4linux-0.15.3.sh
```

Launch the app:

```bash
./Input-0.15.3-Community.AppImage
```

---

## Optional: Udev Rule Setup

Install the necessary udev rules to allow access to your Work Louder device:

Input *should* automatically create these for you.

```bash
curl -sSL https://raw.githubusercontent.com/worklouder/input-linux/main/patch/dist-electron/scripts/install-udev-worklouder.sh | sudo bash
```

Afterward, **unplug and replug your keyboard** before launching the app.

---

## Troubleshooting

- If `node-hid` or `serialport` fail to build and you're using Python 3.12 or newer, ensure the build script properly activates its virtualenv.
- Use Python 3.11+ for best compatibility with `node-gyp`.
- If the app launches but doesn’t detect your device, ensure udev rules are installed (see above).
- The build script defaults to strict mode (`TEST_MODE=false`). You can run in lenient mode like this:

```bash
TEST_MODE=true ./input4linux-0.15.3.sh
```

- The Electron version is auto-detected from the Windows installer. If detection fails, the script will exit with an error pointing to the extracted `app-64/version` file.
- `npm config set python` is no longer needed. The build script uses `export PYTHON=...` automatically.

---

## Contributions

Pull requests are welcome. This project is maintained on a best-effort basis by the community.

---

## License

This project does not claim ownership of Input. Input is a product of Work Louder Inc. This port is provided under an unofficial and permissive approach intended to help Linux users make use of their devices. Refer to the individual license files, if applicable.
