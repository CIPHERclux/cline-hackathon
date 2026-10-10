# Spike S6: capture coexistence matrix (§6.6, §11.4 P-BLACKCAP / P-SCRNSHOT, §15 S6)

The owner fills this in by hand. Results decide the overlay level (D12 → D52).

## How to run one row
1. Run Chalk from Xcode (⌘R, Debug).
2. Open a normal app window (Safari on a Wikipedia page).
3. Click **Test drawing (S4)** in the Chalk panel. Marks stay up for about 8 s while it talks.
4. While marks are visible, take the capture listed in the row.
5. Look at the result:
   - **Content**: is the app content visible, with nothing black or covered?
   - **Marks**: are Chalk's marks absent?
   - **Usable**: are the capture tool's own UI and menus clickable and visible?

**Expected for every row:** content ✅, marks absent ✅, usable ✅.

For ⇧⌘3/4/5, the marks also hide for 10 s as soon as you press the chord, so they vanish on screen too. Other tools rely only on `sharingType = .none`, so the marks stay on your screen but must be missing from the capture.

## Level A: `.screenSaver` (current default)

| # | Capture | Content (no black) | Marks absent | Usable | Notes |
|---|---|---|---|---|---|
| 1 | ⇧⌘3 full screen | | | | |
| 2 | ⇧⌘4 drag an area | | | | |
| 3 | ⇧⌘4 then Space, click a window | | | | |
| 4 | ⇧⌘5 still capture | | | | |
| 5 | ⇧⌘5 screen recording | | | | |
| 6 | QuickTime › New Screen Recording | | | | |
| 7 | Loom window share | | | | |
| 8 | Loom full screen | | | | |
| 9 | Zoom / Meet screen share | | | | |
| 10 | OBS display capture | | | | |

Skip any tool you don't have and write "n/a".

## Level B: `.statusBar + 1` (§6.5's proposal)
Switch in Terminal, then ⌘R in Xcode:
```
defaults write com.yourcompany.leanring-buddy ChalkOverlayLevel statusBar
```
Go back to the default afterwards:
```
defaults delete com.yourcompany.leanring-buddy ChalkOverlayLevel
```

| # | Check | Level A (screenSaver) | Level B (statusBar + 1) |
|---|---|---|---|
| 11 | Rows 1–5 again: ⇧⌘5 toolbar visible and clickable | | |
| 12 | Open Safari's **File** menu, ask *"circle the Print item"*: is the circle visible on top of the open menu? | | |
| 13 | Open a right-click menu over the Wikipedia text: is the blue cursor visible over the menu? | | |

**Deciding:** if both levels pass rows 1–11, keep the level that passes row 12. Pointing into an open menu is a teaching need, and `.statusBar + 1` puts marks under menus.

## Also check (P-DISPLAYS, Spaces)
| # | Check | Expected | Result |
|---|---|---|---|
| 14 | While marks are visible, System Settings › Displays: change the resolution (or plug in or unplug a display) | Marks clear; the blue cursor follows the mouse on every display afterwards; the next drawing lands correctly | |
| 15 | While marks are visible, switch desktops (⌃→) | Marks clear; speech continues | |
| 16 | Press ⇧⌘4, then Esc; wait 10 s | The blue cursor disappears at once and comes back after about 10 s | |

## Results
_Date, macOS version, which tools were tested, and the level decision._
