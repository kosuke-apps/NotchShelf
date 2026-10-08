# Privacy

NotchShelf collects no data and sends nothing anywhere. It contains no network code.

## Kept on your Mac

- **Settings**, in the app's preferences file under `~/Library/Preferences`: the shelf's height,
  the order you arranged the shelf in, the names of menu bar items macOS would not let it move,
  and where macOS last stopped drawing menu bar items.
- **A diagnostic log** at `~/Library/Logs/NotchShelf.log`: when the shelf opened and closed,
  desktop switches, waking from sleep, how many items were behind the notch, and the names of the
  menu bar items you opened or brought out from the shelf. Delete it whenever you like.
- **Icons** of the items behind the notch, held in memory only and never written to disk.

## Permissions

- **Screen Recording**: to copy the icons of the menu bar items behind the notch so the shelf can
  show them. Only those items' windows are captured, never the rest of the screen.
- **Accessibility**: to find out which app owns each menu bar item; to open an item when you click
  it in the shelf; to notice a click on the notch, through a listen-only event tap that checks
  whether a left click lands on the notch and records nothing about any other click; and, for
  Bring out, to command-drag menu bar items, which moves the pointer for about a second.
