# Chalk: agent instructions

> **New session (any harness)? Read "Current state and handoff" below first.** It holds what the owner wants, what is built, where work stopped, and the lessons that cost hours.

The single source of truth is `docs/PRODUCT_SPEC.md`. Current scope is the **Hackathon Demo Cut (§4.7), plus owner-approved D78–D86 UI/debugging and multi-agent guidance work**. Anything marked MVP, v1, Later or v2 is out of scope, even if easy.

## Product
Chalk is a native macOS screen guide for everyday use. You hold a key and ask about whatever is on screen: an error, a setting you can't find, a chart, a maths problem, a DaVinci timeline. Chalk answers out loud while it **points, draws and walks you through steps on your real screen**, like a friend who knows every app. Drawings are timed to the spoken words. It answers first, then shows; for multi-step tasks ("guide me how to colour grade this") it guides one step at a time and waits for you to do each one. Spec v0.2 refocused the product from teaching to general use (D67); protocol and config names (Teaching Script, `teaching` slot, `tutor-engine`) keep their names.

Governing loop (top of spec): **listen → see → speak + point + draw → guide → confirm**. Every change must strengthen this loop; otherwise it is out.

## Hard constraints (never violate)
- **Minimum macOS 26** (SpeechAnalyzer). This dev Mac runs macOS 27 with Xcode 27.
- **Reasoning only through Cline**, via the bundled `tutor-engine` sidecar on an **exact-pinned `@cline/sdk`** (§7.3). Agent turns (conversations, long answers, mid-walkthrough questions) use ClineCore sessions; walkthrough helpers (planner, scout, checker, fixer) and quick calls (filler, zoom, "where is it") use the engine's `complete` fast path, the same SDK's provider client with no agent loop (D74). Never call Anthropic, OpenAI or any model API directly, and never hold their keys. Any Cline-offered model may be used, chosen per slot (§7.4). No Apple Foundation Models. Until hackathon-day credits, development may use the `dev` profile (Gemini free tier) **through the same ClineCore path**; the demo runs on the `demo` profile (D37).
- **Apple-native speech only:** SpeechAnalyzer/SpeechTranscriber in, AVSpeechSynthesizer out (§7.6). No cloud STT/TTS.
- **The overlay is always click-through** (`ignoresMouseEvents = true`). The only exception is the draw-chord panel while ⌃⌥ is held (§4.2.5).
- **Never touch the user's real cursor or keyboard.** We draw a ghost cursor. Event taps are listen-only. No synthetic events (§3.5, §4.2.6).
- **Screenshot only on an explicit trigger:** hotkey, a walkthrough step the user started, or a lasso (§3.7, §10.1). No background capture, no activity logs.
- **Accessibility reads (D74, owner-approved):** only the front app's tree, only during a turn or walkthrough the user started, off the main thread with a time and node budget; never in the background, never logged or stored. Apps without a usable tree fall back to OCR and the vision path.
- **No leftover marks:** the annotation registry is empty (except pinned/board items) on every terminal state (§4.2.2 rule 5, test P-LEFTOVER).
- **Ink budget:** at most **3 emphasis marks + 1 spotlight** (+ current step badges) at once; the renderer enforces it (§4.2.2 rule 2).
- **No full-screen fills** in overlay windows (§0.3, P-BLACKCAP). Overlays use `sharingType = .none` by default (§6.6).
- **No usage on screen or in logs:** never show or log credits, tokens or cost (D66).
- **Idle means idle:** no timers, display links or polling while nothing is visible (§6.5, P-IDLECPU).

## Repo map
| Path | What lives there |
|---|---|
| `docs/PRODUCT_SPEC.md` | Spec (source of truth). Cite sections as `§x.y` |
| `docs/DEMO_PLAN.md` | Ordered demo slices with acceptance checks |
| `docs/DEMO_PROGRESS.md` | Slice checklist, updated at the end of every slice |
| `docs/DEMO_DECISIONS.md` | Ambiguities, conflicts, picks (IDs `Dnn`) |
| `Chalk/` | App target (AppKit/SwiftUI). File-system-synchronized group: new files are compiled automatically |
| `ChalkTests/`, `ChalkUITests/` | App-hosted tests (launch the app; see D07) |
| `Packages/ChalkCore/` | Local SwiftPM package (S03), linked to the app target, for pure, headless-testable logic: Teaching Script parser, ScreenSpace, marks/NMS, lifecycle registry, completion scorer, router rules (D08) |
| `Sidecar/` | `tutor-engine`: TypeScript on `@cline/sdk` ClineCore, bun-compiled, NDJSON over stdio (§7.3) |
| `Sidecar/resources/clinerules/`, `Sidecar/resources/skills/` | Persona rules and app skill packs in Cline `SKILL.md` format (§7.5, §4.2.7) |
| `Eval/` | Pointing check (`pointing/`), probe images, results (§6.8); real screenshots stay local (gitignored) |
| `Config/` | `Signing.xcconfig` (committed) includes the gitignored `Signing.local.xcconfig` |
| `scripts/` | Release pipeline (not in demo scope) |
| `.claude/skills/` | On-demand skills (see below) |

## Commands
Run from the repo root. `build/` is gitignored.
```bash
# The app embeds the engine binary: build it FIRST on a fresh clone, or the Xcode build fails (D45)
cd Sidecar && bun install --frozen-lockfile && bun run build:bin

# Swift app: compile check only. Never launch this product for manual testing; run from Xcode ⌘R (D07)
xcodebuild -project Chalk.xcodeproj -scheme Chalk -configuration Debug \
  -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO | tail -20

# Pure logic tests (no app launch, no TCC)
swift test --package-path Packages/ChalkCore

# App-hosted tests: launch Chalk.app; only with owner approval (D07)
xcodebuild test -project Chalk.xcodeproj -scheme Chalk \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ChalkTests

# Swift lint: uses the repo .swift-format (4-space house style, D34). Legacy code has pre-existing
# diagnostics; a change must add none on the lines it adds
swift format lint --strict <changed .swift files>

# Sidecar: bun 1.4.2 and node 22.23.3 via Homebrew (D09); both on PATH
# Exact-pinned @cline/sdk 0.0.90; bun.lock is committed; no trustedDependencies (D31)
cd Sidecar && bun install --frozen-lockfile
cd Sidecar && bun run typecheck      # tsc --noEmit
cd Sidecar && bun test               # contract tests against the stub provider (no credits)
cd Sidecar && bun run build:bin      # scripts/build-bin.ts → Sidecar/dist/tutor-engine (D32 stand-ins)
cd Sidecar && CHALK_ENGINE_BINARY="$PWD/dist/tutor-engine" bun test   # same suite against the binary
Sidecar/scripts/s0-coldstart.sh      # launch → first pong, p50 ≤ 600 ms

# Walkthrough use-case simulator (D86): scripted screens in Eval/usecases/*.json, a simulated user,
# real model calls through the compiled engine (free dev profile; --profile demo spends credits: ask first).
# Never launches Chalk.app. Report: Eval/results/guide-sim-<profile>-<date>.md. GUIDE_SIM_VERBOSE=1 prints replies.
swift run --package-path Eval/guide-sim GuideSim [--scenario mail-write,flights-cheapest] [--profile dev]

# Talk to the engine by hand on the free dev profile (D37); key from the Keychain, never a file
cd Sidecar && CHALK_MODEL_PROFILE=dev GEMINI_API_KEY="$(security find-generic-password -s chalk.dev.gemini-api-key -w)" ./dist/tutor-engine
#   then type: {"id":"r1","op":"start","slot":"teaching","prompt":"hello"}
```
Tests and harnesses must use the **stub provider** (an OpenAI-compatible local server set via the SDK `baseUrl`, §11.1). Real Cline calls spend hackathon credits and run only in the S02 harness or by hand.

## Definition of done (every change)
1. Builds (`xcodebuild … build`), and `swift test` and `bun test` pass for the touched areas.
2. No new idle timers, polling or display links. Anything periodic runs only while marks, a walkthrough step or audio are active (§6.5).
3. A spec section is cited in code comments for non-trivial decisions, in the commit message and in `docs/DEMO_PROGRESS.md`.
4. Ambiguities are logged in `docs/DEMO_DECISIONS.md`. [ASSUMPTION]/[OPEN QUESTION] items are not built on without a logged decision.
5. The diff is reviewed against §3 principles and the applicable §11.4 pitfalls.
6. A "could not verify" list is written for the owner (audio, overlay placement, permissions, visual accuracy).

## Conventions (kept from the original codebase)
- **Clarity over concision.** Long, specific names (`originalQuestionLastAnsweredDate`, not `originalAnswered`). No single-letter names. Pass arguments under the same name as the variable.
- SwiftUI unless AppKit is required (`NSPanel`, overlays). All UI state on `@MainActor`. async/await. Comments explain *why*.
- Buttons show a pointer cursor on hover.
- App directory, target, scheme and module are `Chalk`; keep their references consistent. The installation bundle identifier remains stable for TCC and stored settings.
- Don't fix the known non-blocking warnings (Swift 6 concurrency, deprecated `onChange` in `ScreenBeaconOverlay.swift`).
- Don't refactor or "improve" beyond the slice. Don't add docstrings to code you didn't change.
- Git: branch `feature/<slice-id>-<desc>`; imperative commit messages that cite `§`; never force-push `main`. Signing lives in `Config/Signing.local.xcconfig` (gitignored; ad-hoc with a pinned designated requirement so TCC grants survive rebuilds, D36), included by the committed `Config/Signing.xcconfig`, the app target's base configuration. Never put a team or identity in `project.pbxproj`; pbxproj changes are otherwise normal and committable.

## Skills (load on demand)
- `.claude/skills/slice-workflow`: how to implement one slice (start here for any slice).
- `.claude/skills/teaching-script`: Teaching Script v1 schema, actions, anchors, lifecycle, demo primitives.
- `.claude/skills/cline-sidecar`: ClineCore embedding, IPC, slots, streaming, steer/abort, prewarm, usage, stub provider.
- `.claude/skills/grounding-and-capture`: capture, OCR, set-of-marks, verification, coordinates, overlay/screenshot coexistence.

Progress: `docs/DEMO_PROGRESS.md`. Plan: `docs/DEMO_PLAN.md`.

## Current state and handoff (D86 — 2026-10-10)

### Walkthroughs: one coordinator, parallel helpers, shared ledger (D86)
- **Core:** `Packages/ChalkCore/Sources/ChalkCore/Guide/`: `GuideCoordinator` (the state machine), `GuideAgents` (prompts and lenient parsers), `GuideCandidateAssessor`, `GuideTypes` (environment/delegate protocols), `GuideDecision`. Pure and headless, driven by the app and by the simulator alike.
- **Helpers:** each is one bounded, stateless `complete` call reading the same `GuideLedger` (goal, task-start date, verified outcomes, the user's choices, notes, last action). Chalk coordinates them; no agent calls another; SDK spawn/teams stay off.
  - **Planner** (teaching slot, Sonnet 5.5) gives the next single action on the current screen as one JSON line, used the moment it parses.
  - **Scout** (teaching, background) predicts the next step while the user acts, with a precondition. It can also say `finishes`, which skips planning and goes straight to the goal check.
  - **Checker** (fast, Haiku 5.5) answers four questions: did the step work, is the prediction right, is the goal reached, which option did they mean.
  - **Fixer** (deep, Opus 5.5) runs only after two failures.
- **Why stateless:** measured on the dev profile, a direct call is ~0.7 s faster than a session turn. Parallel helpers can't share one session anyway, so the ledger is the shared memory.
- **Next step:**
  - A scout prediction that matches the new screen exactly (app, precondition, control enabled and named) is shown with no model call.
  - A plausible one goes to the checker, racing the planner.
  - If the scout is still thinking, it races a fresh plan.
- **Done detection, all local first:**
  - The step's predicate on the tree, after one settled look.
  - A click on the circled control that makes the app react (window, focus, page, dialog, selection or tree changed).
  - Typing finishes on Return, Tab, focus moving on, or 2.5 s idle, and never on a half value.
  - The checker looks only when the app can't tell. If the checker fails, a click on the circle is trusted.
  - Predicates match whole words. A predicate that only names the clicked control is dropped. A typing check becomes value_contains on the field.
- **No friction cards:**
  - A missing control is planned around silently; the fixer steps in after two misses.
  - Consequential actions get a spoken heads-up ("This sends the email."), never a confirmation card: the user's own click is the confirmation.
  - Cards appear only for a real ambiguity the planner asks about. A spoken answer is matched exactly, then by the checker; a free answer becomes the user's direction.
  - The checker can tell the user why a step isn't done yet ("Press Return to run the search.").
- **App side:** `Chalk/WalkthroughController.swift`.
  - Observes: a cheap tree read, or a full read with a settled screenshot (until two captures differ by under 0.8 %, max 1.2 s) plus OCR words for apps without a tree.
  - Presents a step: tree, then Dock, then the planner's fresh point, then OCR, then one locate call; circle and speech together.
  - Watches only during a walkthrough: listen-only input, accessibility notifications, app switches.
  - Streams helper calls with the slot's fallbacks, a deadline and an abort.
  - The first step reuses the key-down screenshot.
  - Saved how-tos are tried as predictions.
  - Mid-walkthrough questions still use a ClineCore session turn.
- **Removed:** the D84 rolling Guide session, `AdaptiveAgentTeam`, `AdaptiveWorkflow`/`StepOutcomeTracker`/`RollingGuidePlan`, and the `adaptive_guide` rule overrides.

### Validation and manual follow-up
- **Builds and tests:** core tests 196/196 (10 new coordinator tests), engine tests 38/38 (source and compiled binary), app build SUCCEEDED.
- **Simulator** (free Gemini flash-lite, `Eval/results/guide-sim-dev-*.md`): 7/7 scenarios reach the goal with 0 wrong circles. Scenarios: dark mode, Mail write/send, Mail not open, cheapest flight, flights done the user's own way, Canva invitation, DaVinci warmer with no tree.
  - A matching prediction shows the next step 0.6–0.9 s after the user acts; a planner step takes ~2–3 s on flash-lite.
  - Free-tier rate limits caused the remaining stalls.
  - These are not Claude timings: run `--profile demo` only with the owner's OK.
- **Owner hand test:** `docs/ADAPTIVE_GUIDANCE_TESTING.md`.

### Historical pre-D78 handoff (reference only)
- Branch feature/S12b-ux-polish; not merged/pushed. Older checks below describe pre-rebrand behaviour and do not override D86 above.

### Who the owner is and how they work
- Builds Chalk for the **Cline AI Builder hackathon**; a new Cline account (amey.taksali@gmail.com) is signed in. Values **user experience above everything**; terse, frustrated feedback when something feels "stale", slow or wrong. Explain plainly, then act.
- Standing rules: English names only, no India-specific framing; **never show or log credit/token/cost figures anywhere** (D66); ask before spending Cline credits on tests (the free `dev` Gemini profile is fine); never push or merge without being asked; don't launch the app yourself (D07): the owner hand-tests and pastes Xcode console logs; the Gemini dev key lives only in Keychain (`chalk.dev.gemini-api-key`), never in files.
- Models: **Claude 5.5 family through Cline**: `fast` = `anthropic/claude-haiku-5.5` (fallback Haiku 4.5; unverified on the account, a "model not found" falls back automatically), `teaching` and `grounding` = `anthropic/claude-sonnet-5.5`, `deep` = `anthropic/claude-opus-5.5` (`Sidecar/model-routing.json`).

### The experience the owner confirmed (build toward this, test against it)
1. **Always points**: every step that involves a click or typing has a circle exactly on that control, appearing as the step is spoken; never a wrong spot, never a step without a pointer.
2. **Fast**: voice within ~1–2 s of asking; the next step ~0.5 s after the user acts; no model wait between simple steps.
3. **Keeps up**: done another way, ahead, back, wandered off, another app, a dialog: it continues from where the user is; never confused, never repeats itself ("Google Flights is open" again and again was a real bug), never restarts.
4. **Starts from where the user is**: the app or browser already open, shortest normal path; no Spotlight/Finder detours unless needed.
5. **Short calm speech**: one short instruction per step; no filler chatter, no talking over itself, never reads internals ("ellipse"); the circle goes once the user acts.
6. **Talk mid-way**: next, back, skip, repeat, why, "I'm lost", questions.
7. **Never clicks or types for the user** (point and explain only). One step at a time with "Step N of M"; every step spoken briefly; speed first.
8. Answers (not walkthroughs): brief spoken answer + circles on the relevant things; maths as clean LaTeX on the whiteboard in sync with speech, concise.
Demo use cases: cheapest flight on Google Flights; write and send a mail; Canva invitation; DaVinci colour grade; "where is this setting"; simplex on the whiteboard.

### Architecture as built
- **Voice**: ⌃⌥ push-to-talk → Apple SpeechAnalyzer (on-device) → `TeachingTurnController.ask` → speech via `VoiceOut`, which keeps **its own sentence queue** and hands AVSpeechSynthesizer one utterance at a time (pause/continue between utterances crashed AVFoundation, D73); the gap after a sentence waits (≤ 8 s) while the whiteboard pen is still writing. Rate 0.78, 0.6 s between sentences. One opener per turn (fixed ack *or* a question-aware Haiku filler, never both). Empty presses ≥ 1 s say "Sorry, I didn't catch that" / "I can't hear your microphone"; the recorder rebuilds on audio-device changes (D71).
- **Engine** (`Sidecar/`, bun-compiled `tutor-engine`, NDJSON over stdio): **agent turns** = ClineCore sessions (answers, walkthrough plans/re-plans, mid-walkthrough questions; one session per walkthrough; earlier screenshots dropped from history); **fast path** = op `complete` (`Sidecar/src/direct.ts`): one streamed call via `Llms.createHandler` with the SDK's Cline sign-in, own short system prompt, no tools/rules/session files, falls back to a one-shot ClineCore turn if it can't start. Fast path is used for the filler, zoom pass, walkthrough looks, quick checks, locate, dialogs. Only tool left: `create_flashcard` (Haiku used to call step tools instead of writing lines; removed, D73). Rules (Cline `.clinerules`, compiled into the binary): `Sidecar/resources/clinerules/00-teacher.md` (persona), `10-teaching-script.md` (script format), `20-grounding.md`, `30-safety.md`, `40-walkthrough.md` (plan format). After editing rules: `cd Sidecar && bun run build:bin`.
- **Perception and pointing**: ScreenCaptureKit capture of the cursor display + Apple Vision OCR candidates + **the front app's accessibility tree** (`AccessibilityService.swift`, off-main, 2500 nodes / 0.35 s budget, menu bar + focused window, Dock readable, Chromium/Electron get `AXManualAccessibility`/`AXEnhancedUserInterface`). Accessibility controls join the snap targets (`Mark.isFromAccessibility`, ids ≥ 100000), so answer circles land on real controls and skip the OCR re-check. Text targets fall back to their `near` point; zoom pass for guesses.
- **Walkthroughs**: see "Walkthroughs: one coordinator, parallel helpers, shared ledger (D86)" above. Intent detection is unchanged (`WalkthroughIntent`: "guide…", "I have to… what should I do", "how do I" + task verb); an answer that starts listing steps hands over to the coordinator. End: recap card, saved how-to, memory updated.
- **Other features**: whiteboard (SwiftMath LaTeX, `numberline`/`geometry`, tableaux converted from `array` to `matrix`, long left sides not aligned on "="); lasso chooser Explain/Summarise/Translate; study and kids modes; user memory (`remember` lines, panel editor); saved how-tos; step HUD (Back/Skip/Stop); presenter mode. Local data: `~/Library/Application Support/Chalk/{memory.json,howtos.json}` (0600).

### Key files added this period
| File | What |
|---|---|
| `Chalk/WalkthroughController.swift` | App side of the guide coordinator: observe, present (find + circle + speak), watch input, stream helper calls |
| `Packages/ChalkCore/Sources/ChalkCore/Guide/` | `GuideCoordinator`, `GuideAgents`, `GuideCandidateAssessor`, `GuideTypes`, `GuideDecision` (D86) |
| `Eval/guide-sim/`, `Eval/usecases/` | Use-case simulator and scenarios (D86) |
| `Chalk/AccessibilityService.swift` | Front-app/Dock accessibility snapshots, change observer, AX→native-pixel conversion |
| `Chalk/GuideCards.swift`, `RegionActionChooser.swift`, `WorkspacePreferencesView.swift`, `UserDataStore.swift` | Step HUD + recap card; lasso chooser; panel modes/how-tos/memory; local storage |
| `Packages/ChalkCore/Sources/ChalkCore/Walkthrough/` | `WalkthroughStep`, `WalkthroughSession`, `WalkthroughPrompts` (plan/replan/question/look/check/locate/dialog), `DonePredicate`, `WalkthroughNavigator`, `WalkthroughIntent` (+ commands, titles), `WalkthroughCheck` (thumbnails, triggers), `KeyboardShortcut` |
| `Packages/ChalkCore/Sources/ChalkCore/Accessibility/AccessibilitySnapshot.swift` | Node/snapshot model, `ElementQuery`, `AccessibilityMatcher` |
| `Packages/ChalkCore/Sources/ChalkCore/Memory/UserMemory.swift`, `Spatial/RegionAction.swift` | Memory + modes; lasso actions |
| `Sidecar/src/direct.ts` | The fast path (`complete` op) |

### Debugging
- The app logs to the unified log, readable without the owner: `/usr/bin/log show --predicate 'subsystem == "com.chalk.app"' --last 1h --info --style compact` (in zsh use `/usr/bin/log`; `log` is a builtin). Prefixes: 🧭 walkthrough (`found by accessibility/text/model look`, `look (…) →`, `step done (…)`, `jumped ahead`, `paused`, `re-plan (…)`), ⏱️ turn latency (slot, model, ms), 🖍️ circle sync (`sync mark=…` = a circle was drawn), 🎯 grounding (verify/zoom). `print()` lines (📜 script diagnostics, 🎙️ dictation, 🧰 tools) appear only in the Xcode console the owner pastes.
- Crashes: `log show --predicate 'processID == <pid>'`; Xcode stops show as SIGKILL; look for `Fatal error` lines just before.
- **Free model probes** (no Cline credits): run the compiled engine on the dev profile and send one NDJSON request: `cd Sidecar && CHALK_MODEL_PROFILE=dev GEMINI_API_KEY="$(security find-generic-password -s chalk.dev.gemini-api-key -w)" ./dist/tutor-engine`, then e.g. `{"id":"p1","op":"complete","slot":"fast","system":"…","prompt":"…"}` or `{"id":"p2","op":"start","slot":"teaching","prompt":"<walkthrough mode=\"plan\">…</walkthrough>\n\n<request>"}`. `CHALK_DEBUG_EVENTS=1` prints provider traffic to stderr (a `complete` that shows no `provider-fetch` line ran direct). Gemini flash-lite is weak; use it to check formats, not intelligence.

### Lessons that cost hours
- Swift: in `case .a, .b, .c where cond:` the `where` guards **only the last pattern**; it once dropped every walkthrough circle (D76). Put the condition on one pattern (`case .x(let action) where cond && isDrawing(action)`).
- Never call `AVSpeechSynthesizer.pauseSpeaking`/`continueSpeaking` between queued utterances (fatal "already speaking", D73); `VoiceOut`'s own queue is the way to delay sentences.
- Fast models drift from free-form formats and call tools if any exist: keep fast-path replies to one JSON line with a strict system prompt, parse leniently (code fences, missing fields), accept only predicates the app can read, never infer progress from reworded text.
- ⌘Space and some system shortcuts never reach a global key monitor; the tree read returns Spotlight when its field is focused (D85), and the 1 s poll evaluates the step's predicate.
- SwiftMath has no `array`/`\hline`; tableaux must be `matrix`/`bmatrix` (`LatexMath.compatible`).
- Accessibility frames are global top-left points; convert with `ScreenSpace.accessibilityRectToNativePixels(_:mainDisplayHeight:)`.
- A step's app may still be launching when the step starts; wait for it before judging "already done" or pausing (D76).

### Open items (what to do next)
1. Owner hand test of D86 guidance (`docs/ADAPTIVE_GUIDANCE_TESTING.md`); fix from Live Logs. With the owner's OK, run the simulator on `--profile demo` for real Claude timings.
2. Confirm `anthropic/claude-haiku-5.5` answers on the Cline account (ask before spending credits); the ⏱️ lines show which model answered.
3. Normal answers still wait ~5–7 s for Sonnet's first sentence (filler covers it); candidate: first sentence + circles from Haiku while Sonnet continues.
4. Remaining demo slices: S11 app skill packs (DaVinci, Preview PDF, VS Code), S13 check chip, S14 sign-in + "under the hood" view (no usage figures), S15 rehearsal cache; then merge `feature/S12b-ux-polish` when asked.
5. Keep `docs/DEMO_DECISIONS.md` (next id D87) and `docs/DEMO_PROGRESS.md` updated with every change; commit with explicit paths and the attribution line the harness provides.
