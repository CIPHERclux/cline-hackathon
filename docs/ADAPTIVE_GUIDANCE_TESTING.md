# Guided walkthroughs: owner hand test (D86)

## Before you start
1. Open `Chalk.xcodeproj` and run the **Chalk** scheme with ⌘R. Quit any older Chalk that is running.
2. Open **Live Logs** from the menu-bar panel and filter for `🧭`.
3. Don't really send, buy or delete anything.

## What to read in the logs
- `step N shown via planner | scout | saved | scout+checker`. The `… ms after the user acted` part is the wait you felt between steps.
- `planner / scout / checker / fixer <ms>`: how long each helper took. `(unusable)` means its reply couldn't be used.
- `prediction strong | rejected (…)`: whether the scout's guess was used.
- `step N done (…)`: how Chalk knew the step was done.
- `recovery: …`: Chalk re-planned on its own.

## Cases

Pass criteria for every case:
- Every action step has a circle on the right control.
- The circle appears as the step is spoken.
- No step repeats.
- No card unless something really needs your choice.

| # | Start from | Say | Also check |
|---|---|---|---|
| 1 | System Settings open on General | "Turn on dark mode" | Step 2 shows under 1 s after your click (`via scout`). It finishes right after Dark is selected. |
| 2 | Mail open on the inbox | "Write an email to (your own address) saying I'll be late, and send it" | Typing the subject, then clicking into the body with no Return, moves on by itself. "Send" gets a spoken heads-up and no card. |
| 3 | Finder in front, Mail closed or in the Dock | "Start a new email to (your address)" | It starts in the Dock, not Spotlight. It stops once the To field is filled. |
| 4 | Chrome on google.com/travel/flights | "Find the cheapest flight from London to Paris next Friday" | "Next Friday" is the right date. The suggestion list and date picker are guided inside them. It finishes at results sorted by price. |
| 5 | Same as 4 | Type Paris and open the date picker yourself before Chalk asks | It notices and carries on from where you are, with no repeat of "type Paris". |
| 6 | Same as 4, mid-way | Switch to another app for 5 s, then back | The HUD shows Paused, then the step comes back. |
| 7 | Same as 4, mid-way | Say "I'm lost" | One new step from what's on screen, saying where it is. |
| 8 | Same as 4, mid-way | Ask "why this step?" or another question | A short answer, then "Back to it." with the circle back. |
| 9 | Canva home in Chrome | "Make a birthday invitation for Maya and download it" | A single "Type … and press Return" step for the search, not two steps. A template question appears only if it's genuinely unclear. |
| 10 | DaVinci Resolve, Edit page | "Make this clip look warmer" | Circles land on Color, then on a wheel or the Temp control, found by text or the model, since DaVinci has no readable controls. |
| 11 | Any app | Hold the talk key during a step and say nothing | The circle comes back with no speech. |
| 12 | A saved how-to from the panel | Run it | Steps that fit appear instantly (`via saved`); the planner fills any gap. |

## Send back
- Any wrong circle, repeat, stall over 5 s, or unexpected card: note the case number and what you saw.
- Copy the Live Logs lines (`🧭`) for that case. Live Logs warns before copying.
