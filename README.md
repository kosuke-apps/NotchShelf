# NotchShelf

On a MacBook with a notch, menu bar items that do not fit to the right of the notch disappear
behind it: macOS stops drawing them, and clicking the notch does nothing. NotchShelf turns the
notch into a button. Click it, and the items hiding behind it drop down in a shelf shaped like the
notch itself; click one to open it.

- **Click the notch** to open the shelf. Click the notch again, or anywhere else, to close it.
- **Click an item** in the shelf: it does what it does when clicked in the menu bar.
- **Right-click an item** for Open, or Bring Out of the Notch.
- **Option-click an item** to bring it out of the notch.
- **Drag items** in the shelf to change their order there.
- **Right-click an empty part of the shelf**, or open the app again, for settings.

NotchShelf puts nothing in the menu bar itself: no icon of its own, and nothing over the menu bar
while the shelf is closed. It never takes space from the items it is meant to rescue.

## What it cannot do

These are limits of macOS, not settings.

- **A right-click cannot reach an item behind the notch.** Opening works through the accessibility
  "press" command, which runs an item's main action. There is no command for a right-click, and an
  item macOS does not draw cannot receive a mouse event. Apps that do something different on a
  right-click only get their left-click behaviour from the shelf.
- **Bringing an item out always sends another one behind the notch.** The space to the right of
  the notch is fixed: items can be reordered, but not made to take less room. Bring out takes the
  item nearest the notch, and borrows the pointer for about a second to command-drag it.

## Requirements

- A Mac with a notch.
- Built and tested on macOS 26 (Tahoe). The declared minimum is macOS 14, which has not been tested.

## Permissions

| Permission | Why |
|---|---|
| Screen Recording | To copy the icons of the items behind the notch. Only those items are captured. |
| Accessibility | To see which app owns each item, to open an item from the shelf, to notice a click on the notch, and to rearrange the menu bar for Bring out. |

NotchShelf opens its settings window on first launch, with a button for each permission.
[PRIVACY.md](PRIVACY.md) lists what is kept and where.

Builds made before the first release used the bundle identifier `com.kosuke.NotchShelf`. Their
settings are carried over on first launch, but their permission entries are not; remove them in
System Settings, or with `tccutil reset ScreenCapture com.kosuke.NotchShelf` and
`tccutil reset Accessibility com.kosuke.NotchShelf`.

## Install

1. Download `NotchShelf-0.1.0.dmg` from [Releases](https://github.com/kosuke-apps/NotchShelf/releases).
2. Open it and drag NotchShelf onto Applications.
3. Open NotchShelf from Applications. The app is signed but not notarized, so macOS refuses to
   open it the first time. Open System Settings → Privacy & Security, find the message about
   NotchShelf, and click Open Anyway.
4. Grant Screen Recording and Accessibility when asked.

To check the download, compare its checksum with `NotchShelf-0.1.0.dmg.sha256` from the same
release:

```sh
shasum -a 256 -c NotchShelf-0.1.0.dmg.sha256   # in the folder holding both files
```

## Build from source

Requires the Swift toolchain; the tests need Xcode's.

```sh
Scripts/install.sh   # builds, signs, and installs to /Applications
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

`Scripts/build-app.sh` signs with a self-signed certificate named `Mac Utilities Code Signing`
when your keychain has one, so that macOS keeps the permissions across rebuilds. Without it the
build is signed ad hoc, and the permissions have to be granted again after every rebuild.

## License

MIT; see [LICENSE](LICENSE). NotchShelf uses only Apple's frameworks; see
[THIRD_PARTY.md](THIRD_PARTY.md).

This app was built with the help of Claude (Anthropic) through Claude Code; design, review and testing are by Kosuke Satake. Anthropic does not endorse this app.
