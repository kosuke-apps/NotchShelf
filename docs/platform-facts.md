# Platform facts

What NotchShelf's design rests on, as measured. Read this before changing how items are found,
opened, or moved, and before trying something listed here as failing.

Measured on macOS 26.6, 14-inch MacBook Pro (1800 x 1169 points, notch from x=790 to x=1010).

- Every status item window is composited by Control Center (the window list names it as the
  owner). The window name is the item's `autosaveName`, or `Item-N`.
- An item whose frame starts left of the drawing boundary gets no on-screen window. The boundary is
  not exactly the notch edge: hidden items started as far right as x=1029, drawn ones as far left
  as x=1036. It is read from the layout: the leftmost drawn item.
- Hidden items still appear in `CGWindowListCopyWindowInfo(.optionAll)` (off screen), and in their
  owning app's `AXExtrasMenuBar` with correct positions and a working `AXPress`.
- Hidden items cannot be clicked, dragged, or hit-tested at their coordinates.
- No right-click can reach a hidden item. There is no accessibility command for it, and during
  `AXPress` the app's `NSApp.currentEvent` is nil. A right-button event posted to the owning app
  arrives with window number 0, because its status item windows only have app-local numbers
  (`n << 32`) that a `CGEvent` cannot carry, and the app drops it. Posted to Control Center, it
  reaches nothing.
- Reordering works only as a real command-drag through the HID event tap, which moves the pointer.
  Posting to the process, writing `NSStatusItem Preferred Position` (read only at app launch),
  setting the accessibility position (unsupported), and writing `NSStatusItem Visible` all fail.
  An external app cannot remove another app's item, and blank spacer items of its own were not
  reliably given a slot, so it cannot make room.
- With a full-screen app in front or the menu bar hidden, every status item reports off screen;
  the layout is unchanged. While Spaces slide, items are reported far off screen (x=2923, x=-686)
  and "System Status Item Clone" windows appear.
- A global `NSEvent` mouse monitor missed notch clicks away from the first desktop; the cause was
  not established. A listen-only `CGEventTap` sees them.
- Once, a few minutes after waking from sleep and right after a desktop switch, the reused shelf
  panel opened on another Space (visible, `isOnActiveSpace == false`). It was not reproduced
  without a sleep. A newly created panel appeared on the active Space in every test.
