# FloatNote

A tiny always-on-top scratch window for macOS. Paste text or images into it, and it floats above every app, every Space and full-screen windows. So you can copy from it into whatever you're working on without swiping between desktops after every line.

It also does **line-by-line copying**: press a hotkey from any app and the next line lands on your clipboard, ready to ⌘V.

## Features

- **Always on top.** Stays above other windows, on every Space, including over full-screen apps.
- **Text and images.** Paste or drag in anything. Big images shrink to fit the window.
- **Copy the next line from anywhere.** <kbd>⌃⌥C</kbd> copies the next line (or image) without touching the window. Blank lines are skipped. Click any line to make it the next one.
- **Readable by default.** Pasted text is converted to the system font and colors, so it works in light and dark mode. Bold, italic and monospaced code are kept. Smart quotes and autocorrect are off, so code is pasted exactly.
- **See-through background.** A slider fades only the window's background. Text and images stay solid.
- **Minimal.** No title bar and no Dock icon, just a menu bar icon.
- **Remembers everything.** Content, position, size and transparency survive restarts.

## Shortcuts

| Shortcut | Works from | Action |
|---|---|---|
| <kbd>⌃⌥C</kbd> | any app | Copy the next line to the clipboard |
| <kbd>⌃⌥R</kbd> | any app | Restart line copying from the top |
| <kbd>⌃⌥Space</kbd> | any app | Show / hide the window |
| <kbd>⌘W</kbd> | FloatNote | Hide the window |
| <kbd>⌥⇧⌘V</kbd> | FloatNote | Paste as plain text |
| <kbd>⌘F</kbd> | FloatNote | Find |

## Install

### Download

Grab `FloatNote.zip` from the [latest release](../../releases/latest), unzip it, and move `FloatNote.app` to Applications.

The app isn't notarized by Apple, so the first launch is blocked. Either right-click the app → **Open** → **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/FloatNote.app
```

### Build from source

Requires macOS 11+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/<your-username>/FloatNote.git
cd FloatNote
./build.sh && open FloatNote.app
```

Use `./build.sh --universal` for a build that runs on both Apple Silicon and Intel Macs.

## Usage

1. Launch FloatNote. A window appears, along with a picture-in-picture icon in the menu bar.
2. Paste the stuff you need to copy from: a list, code, notes or screenshots.
3. Switch to the app you're working in. Press <kbd>⌃⌥C</kbd>, then <kbd>⌘V</kbd>. Repeat.
4. Drag the window by the handle at the top or by an empty spot on the bottom bar. Resize it from any edge.

To quit, click the menu bar icon and choose **Quit FloatNote**.

## Customizing

Everything is in [`Sources/main.swift`](Sources/main.swift), a single file of about 500 lines.

- **Hotkeys:** change the key codes in `registerHotKeys()`. The modifiers are set in `register(keyCode:id:)`.
- **Font size:** `baseFontSize`.
- **Window size and style:** `buildPanel()`.

Saved content lives at `~/Library/Application Support/FloatNote/content.rtfd`.

## Releasing

Every push builds the app with GitHub Actions. To publish a release with a downloadable app:

```sh
git tag v1.0.0
git push origin v1.0.0
```

## License

[MIT](LICENSE)
