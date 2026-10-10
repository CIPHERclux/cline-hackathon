# Demo progress

Checklist of slices from `docs/DEMO_PLAN.md` (scope: §4.7). Tick a slice only when its agent acceptance checks pass. Under each ticked slice, record:
- what was done (with `§` refs);
- the check results;
- new decision IDs;
- a **Could not verify** list for the owner.

Gating spikes (§15) are marked ⚑.

- [x] **S00** Hygiene: remove full-screen overlay fill, `sharingType = .none`, `disableAutomaticTermination`, macOS 26 target (§0.3, §0.13, §6.6). Branch `feature/S00-hygiene`.
  - **Done**
    - `ScreenBeaconOverlay.swift`: removed the full-screen near-transparent black fill from `BlueCursorView.body` (§0.3, §6.5, P-BLACKCAP). Set `sharingType = .none` in `ScreenBeaconOverlay.init` (§6.6). The level stays `.screenSaver` (D12).
    - `ChalkApp.swift`: `ProcessInfo.processInfo.disableAutomaticTermination("Chalk is running")` first thing in `applicationDidFinishLaunching` (§0.2, P-AUTOTERM).
    - `project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET` 14.2 → 26.0 in all 4 settings (D11, D33).
    - The existing tests were already broken (wrong module import, actor isolation). Fixed test-only (D35).
    - Added `.swift-format` (4-space house style) so lint is meaningful (D34).
  - **Checks**
    - S00 acceptance script: 4/4 PASS (before the change: 4/4 FAIL for the right reasons).
    - `xcodebuild clean build` (Debug, `CODE_SIGNING_ALLOWED=NO`): BUILD SUCCEEDED. Unique warnings 35 before and 35 after, an identical set (no new warnings).
    - `xcodebuild test -only-testing:ChalkTests`: 3/3 passed, TEST SUCCEEDED (failed identically on pre-S00 commit `d71ec9b` before the D35 fix).
    - `swift format lint --strict`: 0 diagnostics on lines added by S00; pre-existing totals unchanged (58 / 3 with the house config).
    - No new `Timer`, display link, `asyncAfter` or polling in the diff. No forbidden-API strings added. The test host quit after the run.
  - **Decisions:** D33 (acceptance count fix, D12 slice ref), D34 (`.swift-format`), D35 (test target fixes).
  - **Manual verification (owner, 2026-10-02): all pass**
    - The overlay renders and follows the mouse without the fill; onboarding bubble and video show.
    - ⇧⌘4 window, ⇧⌘3 and ⇧⌘5 recording: content shows (not black) and the buddy is excluded.
    - The app survives 10+ min idle (`pgrep -fl Chalk`).
    - It runs from Xcode ⌘R with local ad-hoc signing; TCC grants persist across rebuilds (D36, D07).
- [x] **S01** ⚑ S0: `tutor-engine` sidecar on ClineCore under bun, stub provider, contract tests (§7.3). Branch `feature/S01-sidecar`.
  - **Done**
    - `Sidecar/` (TypeScript on exact-pinned `@cline/sdk` 0.0.90, `bun.lock` committed, no `trustedDependencies`; D31). Implements the §7.3 NDJSON protocol: `ping`, `prewarm`, `start`, `send` (`steer`/`queue`), `abort`, `tool_result`, `usage`, emitting `session`/`text`/`tool_call`/`usage`/`done`/`error`.
    - ClineCore with built-ins hidden (§7.3), proxy tools `create_flashcard`, `advance_step`, `mark_step_done` that round-trip to Swift, and an empty cwd under `CLINE_DIR` (§7.3 Launch).
    - Fast-fail provider errors, mapped to the §7.3 kinds, plus a 15 s response timeout (P-REGION, D38).
    - `model-routing.json` with `demo` (§7.4 slots via Cline), `dev` (Gemini free tier) and `stub` profiles (D22, D37).
    - Screenshot privacy (§7.4, §10.1): earlier screenshots dropped from model requests and scrubbed from the SDK's session files; `CLINE_DIR` files are 0600 (D39).
    - Telemetry off and verified; the binary swaps out `posthog-node` and `node-machine-id` (D32).
  - **Checks**
    - `bun run typecheck`: clean.
    - `bun test` (source, network guard preloaded): **28/28 pass**. Covers acceptance 1–7: (1) start → session → text → usage → done; (2) abort → `done(aborted)` in **1.8 ms** (≤ 100 ms); (3) steer reaches the running turn; (4) tool round trip; (5) the request carries only the 3 proxy tools; (6) 401/403/429/5xx/404/hang/unreachable → error kinds within 1 s; (7) no non-loopback connection, plus a guard self-test.
    - Mutation checks: re-enabling built-ins fails test 5; removing fast-fail fails the 403/429/500/404 tests.
    - `CHALK_ENGINE_BINARY=dist/tutor-engine bun test`: **27/27 pass** (+1 source-only skip).
    - `env -i PATH=/usr/bin:/bin dist/tutor-engine` answers `{"re":"p1","ev":"pong","proto":1}` with no Node or bun on PATH.
    - `scripts/s0-coldstart.sh`: **p50 225 ms** over 10 runs (≤ 600 ms).
    - `lsof` during a turn on the binary: loopback (stub) only.
    - Real call on the `dev` profile via the binary: `teaching` (`gemini-3.5-flash`) first text 3.5 s, `fast` (`gemini-flash-lite-latest`) 1.3 s.
    - No Swift changes (app build and tests not re-run). No idle timers: the only timers run while a provider request or tool call is in flight.
  - **Decisions:** D37 (free dev profile), D38 (protocol details and SDK behaviours), D39 (screenshot privacy); D32 verified.
  - **Could not verify**
    - Notarization with a Developer ID (not shipping, D29); a clean macOS 26 VM.
    - Launching from Swift `Process` (comes with S04).
    - The D20 keyboard-tap TCC question (owner check below).
    - Real Cline calls (no credits until hackathon day, D10).
- [x] **S02** ⚑ S1/S1b/S3: Cline vision probe and slot latency (§7.4, §15). Branch `feature/S05a-pointing-check`. Run 2026-10-03 on the owner's free Cline account.
  - **Done**
    - Probes in `Sidecar/scripts/`: `probe-vision.ts`, `probe-cline-api.ts`, `probe-latency.ts`, `engine-client.ts`, `cline-login.ts`, `cline-balance.ts`. `start` takes an optional `model` (D41).
    - Cline sign-in through the SDK device flow, saved in `CLINE_DIR` with owner-only files (D10 resolved).
  - **Checks**
    - **S1: 9/9 pass** (`Eval/results/S02-vision-demo-2026-10-022002.md`). All 8 §7.4 candidates read 3/3 tagged words + a random number through ClineCore: haiku-4.5, sonnet-5.5, opus-5.5, fable-5.1, gemini-3.8-flash, gpt-6-luna, gpt-6-sol, qwen3-vl. The text-only control `openai/gpt-oss-20b` was detected as blind.
    - **S1b: pass** (`Eval/results/S02-cline-api-2026-10-022003.md`). `image_url` through `api.cline.bot` chat completions; the fallback adapter can send screenshots.
    - **S3: measured, misses the §15 gates** (`Eval/results/S02-latency-demo-2026-10-022004.md`, 15 runs per slot). Haiku TTFT p50 1305 ms; Sonnet TTFT p50 1613 ms, first speak line p50 2053 ms (p95 3261). The owner accepts ~2 s; mitigations go into S04 (D43).
    - `bun test` 33/33 and typecheck clean.
  - **Decisions:** D10 (resolved), D41, D42, D43.
  - **Could not verify:** 50-run latency per slot (15 runs used; redo on hackathon day after the S04 mitigations).
  - **Also on this branch:** S05 pointing check pulled forward (D40). Real screens, free flash-lite: raw + zoom + snap 17/19 (89%).
  - **Hackathon-morning runbook** (credits on the signed-in account):
    1. `cd Sidecar && bun run build:bin`
    2. `bun Sidecar/scripts/probe-latency.ts --profile demo --slots fast,teaching --runs 50` (after S04's mitigations)
    3. `bun Eval/pointing/run.ts --profile demo --slot grounding --modes raw,snap,zoom` (pointing on the real grounding model)
    4. Update `model-routing.json` if needed and commit `Eval/results/`.
- [x] **S03** Teaching Script v1 streaming parser, validator, repair; create `Packages/ChalkCore` (§6.4, §4.2.1). Branch `feature/S03-teaching-script`.
  - **Done**
    - `Packages/ChalkCore` (swift-tools 6.2, macOS 26, one library + one test target, D08), linked to the app target as a local package (15 pbxproj lines: local package reference, product dependency, build file).
    - `TeachingScript/`:
      - `JSONValue` (lenient decode);
      - `TargetDescriptor` (all 5 §6.4 shapes; `px` is low-confidence);
      - `Actions` (§6.4 action table; demo allowlists: 9 shapes from D01, figures `numberline` and `math_steps` from D02);
      - `ScriptValidator` (JSON → action or diagnostic);
      - `StreamingScriptParser` (line buffering across deltas, plain text → `speak`, 2 KB flush, code-fence/trailing-comma/array repair, malformed-rate statistics) (D44).
  - **Checks**
    - `swift test --package-path Packages/ChalkCore`: **22/22 pass**. They cover:
      - the §6.4 example split at every Unicode-scalar boundary (and one scalar per delta) → identical actions;
      - interleaved plain text → `speak`;
      - unknown type dropped;
      - `spotlight`/`bracket`/`freehand`/`plot` dropped;
      - `cite` dropped;
      - 2 KB without a newline → speech;
      - code fences, glued fences, trailing commas and array brackets repaired;
      - malformed JSON dropped and counted;
      - missing target → speech-only;
      - `px` flagged; all 5 descriptor shapes; CRLF.
    - Mutation check: disabling the 2 KB flush fails its test.
    - `xcodebuild … build` with the package linked: **BUILD SUCCEEDED**; `ChalkCore` builds as part of the app; 0 warnings from the package.
    - `swift format lint --strict` on all new files: 0 diagnostics.
    - No app Swift changed; no timers.
  - **Decisions:** D44.
  - **Owner verified (2026-10-03):** the project opens with ChalkCore under Package Dependencies, and ⌘R builds and runs as before.
  - **Not run:** app-hosted `xcodebuild test` (D07: needs owner approval; no app code changed).
- [x] **S04** ⚑ S5: voice loop end to end (SpeechTranscriber → sidecar → AVSpeech), barge-in, delete forbidden-API files (§7.6, §8). Branch `feature/S04-voice-loop`.
  - **Done**
    - **ChalkCore:**
      - `Engine/TutorEngineClient` (actor). Launches tutor-engine, frames NDJSON, gives each request its own event stream, and pings every 10 s only while a turn is in flight. Restarts with 0.5→8 s backoff, at most 5 per minute, and retries an in-flight `start` once if it hadn't produced text (§7.3, P-SIDECAR).
      - `Routing/ModelRouter` (§7.4 rules 1–3 and the vision guard, P-NOVISION).
    - **App:**
      - `SpeechService` (SpeechAnalyzer + SpeechTranscriber, on-device, volatile results, asset install at launch, §7.6).
      - `VoiceOut` (AVSpeechSynthesizer, one utterance per `speak` line as soon as the line completes, anchors stripped, `stopSpeaking(at: .word)`).
      - `TutorEngineHost` (bundled engine, scrubbed env, launch at app start, prewarm on first press, profile switch).
      - `TeachingTurnController`: screenshot at key-down (JPEG ≤ 1568 px, D43), router + vision guard + one fallback, streaming parse → speech, "let me look" after 700 ms, one latency log line per turn plus signposts (§11.3).
    - **Rewired:** `CompanionManager`, `BuddyTranscriptionProvider`, `CompanionScreenCaptureUtility`, the panel (Cline/Gemini profile switch), vocabulary hints.
    - **Deleted (D13):** AssemblyAI, OpenAI audio, ElevenLabs, ClaudeAPI, OpenAIAPI, ElementLocationDetector, BuddyAudioConversionSupport, AppleSpeech (SFSpeech), `worker/`, the Info.plist `VoiceTranscriptionProvider` key.
    - **PostHog** package removed and analytics no-ops (D14); the FormSpark email post is gone.
    - **Sidecar:** `.clinerules` (`00-teacher`, `10-teaching-script`, `20-grounding`, `30-safety`) bundled into the binary and installed into `CLINE_DIR/rules` (§7.5); `send` can switch the model (D45); per-profile vision lists.
  - **Checks**
    - `swift test --package-path Packages/ChalkCore`: **30/30**. Includes the router table (10 cases), the P-NOVISION guard, the real `model-routing.json`, and the client against the compiled engine + stub: speak lines in order, abort, **kill -9 → restart → one retry → answer**, ping.
    - `bun test`: **35/35** (rules reach the system prompt; a model switch on `send` keeps history).
    - Forbidden-endpoint grep over `Chalk` + `worker`: none (`worker/` deleted).
    - `xcodebuild … build`: SUCCEEDED, unsigned and signed. `codesign --verify --strict --deep` OK with the embedded engine.
    - No new compiler warnings from new or changed lines. `swift format lint` clean on all new files and added lines.
    - Idle: no new periodic work (pings only while a turn is in flight; the acknowledgement is a one-shot).
  - **Decisions:** D45 (plus D13, D14 executed).
  - **Owner verified (2026-10-03):** all S04 hand tests pass: real voice turns, barge-in and follow-up, speech permission (mic only), profile switch. Latency feels like about 2 s to the first word (subjective; the 30-question `⏱️` log run for S5 is still to do). The voice sounds robotic: Chalk now defaults to Siri Voice 6 (`8e80c79`), and `Eval/voice-sampler.swift` plays every natural voice so the owner can pick one (override via `defaults write com.yourcompany.leanring-buddy ChalkVoiceIdentifier …`).
  - **Still open:** the S5 measurement (30 questions, paste the `⏱️` lines; redo on Cline on hackathon day); the final voice choice.
- [x] **S05** ⚑ S2: capture, Vision candidates, set-of-marks, grounding harness (§6.2–6.3, §6.8). Branch `feature/S05-grounding`.
  - **Done**
    - **ChalkCore:**
      - `ScreenSpace` (native ↔ model ↔ norm1000 ↔ display points ↔ AppKit global ↔ overlay; the v1 math centralized, per-axis scale);
      - `Perception/` (`Candidate`, `Mark`, `MarkSelection`: NMS, focus/cursor priority, text cap, icon-first, uncapped snap set, snap, prompt list; `VisionCandidateDetector`: OCR + rectangles + tiled contours; `MarksImageRenderer`);
      - the `grounding-marks` tool, now used by the harness, so it measures the app's own code.
    - **App:** `CaptureService` (native capture, model JPEG, ScreenSpace, frontmost window, cursor, secure-input refusal) and `PerceptionService` (off-main, at key-down, Vision warm-up at launch). The turn controller sends the screenshot by `ChalkPointingMode` and keeps `currentScreen` for S06/S08. `CompanionScreenCaptureUtility` deleted.
    - **Rules:** targets prefer labels, then 0–1000 points (D48).
  - **Checks**
    - `swift test`: **44/44** (ScreenSpace incl. negative-origin, 1×/2× and portrait displays, plus the v1 characterization; MarkSelection: NMS, caps, glyph/inner-stroke drops, reading order, focus priority, snap, prompt list, JSON format).
    - `bun test`: 35/35.
    - App build: SUCCEEDED, with no warnings from new code; lint clean on all new and touched files.
    - **Harness (offline):** candidate recall **27/27 (100%)** on the uncapped snap targets (gate ≥ 92%); 25/27 capped.
    - **Model picks** (Flash Lite, free): raw + zoom + snap **17/19 (89%)** on the 19 real-screen targets (gate ≥ 85%); 25/27 including synthetic (`Eval/results/pointing-2026-10-022117.md`).
  - **Decisions:** D48.
  - **Not done / owner:**
    - The golden set has **27 targets (19 real), not 40**: the hero-app screens (~20 targets, D06 Figma vs Blender) and the rest of the 10 PDF + 10 VS Code are still to capture.
    - Re-run the model picks on the Cline grounding model on hackathon day.
    - Confirm no screenshot is written to disk.

- [x] **S06** ⚑ S4: annotation renderer (10 demo primitives), lifecycle registry, voice-synced strokes (§4.2.1–4.2.4, §6.5). Branch `feature/S06-annotations`.
  - **Done**
    - **ChalkCore:** `Annotation/` (`AnchorMapper` + `AnchorScheduler`: marker stripping, UTF-16 anchor offsets, start-on-word, utterance-end flush, group completion; `LifecycleRegistry`: transient 2.0 s, speech-bound per group, step, pinned, board, ink budget 3 emphasis + 1 spotlight, P-LEFTOVER; `RoughStrokeGenerator`: seeded hand-drawn ellipse/ring/rect/underline/highlight/arrow/curved arrow). `Grounding/TargetResolver`: basic §6.2 resolution pulled forward from S08 (D49).
    - **App:** `AnnotationRenderer` (per-display click-through windows, `sharingType = .none`, `CAShapeLayer` `strokeEnd` draws, arrowheads 80 ms later, label chips, 400 ms fades, Reduce Motion), `AnnotationColorRoles` (§5.6), `AnnotationController` (resolve → wait for the anchor word → register → draw; one-shot transient timer; `point` = ghost-cursor flight + ring). `VoiceOut` reports utterance numbers, word ranges and ends; the turn controller routes draw/point/highlight/clear; Esc and the talk key clear marks; the buddy's 60 Hz cursor timer is now event-driven (P-IDLECPU).
    - **S4 tooling:** Debug-only panel button "Test drawing (S4)" (fixed script: 3 sentences, 5 anchors, region targets, no model, no credits) and `Eval/s4-sync.sh` (p50/p95 from the `🖍️ sync` log lines; misses fail the run).
  - **Checks**
    - `swift test`: **62/62** (anchors incl. UTF-16 and replay determinism; registry: transient at 2.0 s, group fades, budget, P-LEFTOVER property test over 500 random scripts × cancel points; rough strokes deterministic per seed; resolver: marks, text, snap, unsnapped box, regions, relative).
    - App build: SUCCEEDED; no warnings from new or changed lines (remaining warnings are the known legacy ones). `swift format lint --strict` clean on new files and added lines.
    - `Eval/s4-sync.sh` checked on synthetic log lines (pass/fail and misses).
  - **Decisions:** D49, D50, D51.
  - **Owner hand test 1 (2026-10-03):**
    - S4 sync: 5/5 anchors on time, delays 0.8–9.5 ms.
    - Pointing works, sometimes exactly on target (raw-point snaps remain for S08).
    - Underline worked.
    - Idle CPU **7.5–8.8%**: fixed (D51).
    - Most first anchors were drawn late because the model sent drawings after their sentence: fixed (D50).
    - The owner asked for the cursor to do the drawing: added as the pen (D50).
    - Mission Control thumbnails are empty: diagnosis pending (D51).
  - **Owner hand test 2:**
    - Small blue circles everywhere and the pen never drew: point + draw duplicates and the v1 flight (log: `penApproachMs=0`). Fixed (D50).
    - Late anchors are gone: 4/4 timed.
  - **Owner hand test 3:**
    - Circle and underline are drawn by the pen.
    - **S4 PASS:** 30/30 timed, 0 misses; onset p50 1.6 ms, p95 2.4 ms (max 8.5 ms); ink after the pen's flight p50 163 ms, p95 252 ms (D50).
    - Mission Control thumbnails are empty only with Chalk running, and `sharingType` isn't the cause.
  - **Owner hand tests 4–5:** the empty Mission Control thumbnails come from the cursor overlay's `.canJoinAllSpaces`. Deferred as a known issue: switch desktops with ⌃←/⌃→ in the demo (D51).
  - **Owner verified (2026-10-03):**
    - Idle CPU **0.0%** (was 7.5–8.8%).
    - The pen draws circles and underlines; S4 passes (above).
    - Known issue: Mission Control (D51).
- [x] **S07** ⚑ S6: capture coexistence, ⇧⌘3/4/5 hide, display rebuild, overlay level decision (§6.6). Branch `feature/S07-capture-coexistence`.
  - **Done**
    - **ChalkCore:** `Hotkeys/ScreenshotChord` (⇧⌘3/4/5 and the ⌃ variants; ⌥ excluded; allocation-free for the tap callback, P-HOTKEY).
    - **App:**
      - The key tap publishes the chord, and every overlay (cursor and annotations) goes to alpha 0 for 10 s (P-SCRNSHOT).
      - Overlays rebuild and marks clear when a display's frame or scale changes (P-DISPLAYS).
      - Marks clear on a Space switch.
      - One shared overlay level, switchable for the matrix (D52).
    - **Eval:** `Eval/S6-capture-matrix.md` (16 rows for the owner).
  - **Checks**
    - `swift test`: **67/67** (+3 chord tests: system chords and ⌃ variants match; harmless flags ignored; no false positives on ⌘3, ⇧3, ⌥⇧⌘4, ⇧⌘6, ⇧⌘A).
    - App build: SUCCEEDED, no new warnings; lint clean on new files and added lines.
    - `! grep -rn 'opacity(0.001)'`: clean.
    - Presenter mode toggle in the panel (D53): drawings show in recordings and shares when on.
  - **Decisions:** D52, D53.
  - **Owner verified (2026-10-03):**
    - Presenter mode on: the recording shows the drawings and the cursor.
    - The 10 s chord hide works (it hid them at the start of a ⇧⌘5 recording; now skipped in Presenter mode).
    - The full S6 matrix was skipped as not demo-critical (owner's call); the level stays `.screenSaver` (D52).
- [x] **S08** Target resolution, verification pass, zoom fallback, ghost point (§6.2 d/f, §6.4). Branch `feature/S08-target-verification`. Merged via S10 after the owner's hand tests (2026-10-03).
  - **Done**
    - **ChalkCore:**
      - `Grounding/FuzzyTextMatch` (exact > prefix > contains > OCR misread ≥ 0.8 similarity for 4+ characters);
      - `TargetResolver` adds `within`, ranked alternatives and `matchedText`;
      - `VerificationCheck` + `GroundingEscalation`;
      - `ZoomPass` (crop, 0–1000 → native, reply parsing);
      - `ScreenSpace.displayPointRectToNativePixels`.
    - **App:**
      - `GroundingService` (fresh-crop verify via `CaptureService.captureRegion` + OCR; zoom pass through the engine's grounding slot with an 8 s timeout);
      - `AnnotationController` zooms guesses before drawing, verifies text marks after drawing (relocate or fade), and asks the learner to circle the target (§5.10).
      - `point` was already the ghost cursor + ring (S06, D50).
    - **Rules:** `px` targets carry a `label`.
  - **Checks**
    - `swift test`: **82/82** (+15: fuzzy ranks and misreads, `within`, ranked alternatives, px low-confidence vs snapped, verification confirm / relocate / not found / not verifiable, escalation after 2, zoom crop and clamp, mapping, reply parsing, rect round-trip).
    - `bun test` 35/35; typecheck clean; engine rebuilt with the new rule.
    - App build: SUCCEEDED, no new warnings; lint clean.
  - **Decisions:** D54.
  - **Not run:** the 40-target golden set (needs approval and credits).
  - **Owner hand test (2026-10-03):**
    - The ring was late (the zoom wait) → now the guess draws on its word and the zoom moves it.
    - After a scroll the label was "not found" → now a full-height column is checked.
    - With no Bluetooth button on screen the model said so (pass).
- [x] **S09** Spatial context: lasso "explain this region" (§4.2.5). Branch `feature/S09-lasso` (stacked on S08). Merged via S10 after the owner's hand tests (2026-10-03).
  - **Done**
    - **ChalkCore:**
      - `Spatial/LassoClassifier` (lasso vs area, bounds, tiny strokes ignored, several strokes merged);
      - `RoughDrawing` public init; `InkKind.learner`.
    - **App:**
      - `DrawChordPanel` (mouse-accepting only while ⌃⌥ is held, active display only, violet trail);
      - `LearnerDrawingImages` (strokes on the model screenshot, native region crop, context line);
      - the turn attaches them; a lasso with no speech asks "Explain the region I circled."; the learner's strokes stay visible during the answer.
  - **Checks**
    - `swift test`: **87/87** (+5 lasso tests).
    - App build: SUCCEEDED, no new warnings; lint clean.
  - **Decisions:** D55.
  - **Owner hand test (2026-10-03):**
    - Explain-region, click-through after release and talk-only all pass.
    - The trail stayed until the answer ended and had no glow → now it glows and leaves on release.
    - The silent-lasso answer was short → fuller prompt.
- [x] **S10** Whiteboard: `numberline` + `math_steps` (§4.2.3, D02). Branch `feature/S10-whiteboard` (stacked on S09). Merged after the owner's hand tests (2026-10-03); hand-test fixes D57–D65 included.
  - **Done**
    - **ChalkCore:** `Figures/` (`NumberLineSpec`/`MathStepsSpec` parsing, `NumberLineLayout` with nice ticks, label thinning and stacking, `MathStepsDiff` token LCS).
    - **App:**
      - `WhiteboardPanel` + `FigureRenderer` (SwiftUI on a non-activating panel);
      - figures and reveals run on spoken anchors through the scheduler; leftovers reveal at the end of the answer; the board persists until closed or replaced.
    - **Rules:** figure and reveal syntax.
    - **Debug buttons:** "Test whiteboard: math steps" (demo step 3, 0.999… = 1) and "Test whiteboard: number line", local with no credits.
  - **Checks**
    - `swift test`: **101/101** (+14: spec parsing, validator scope, ticks, nice steps, labels, thinning, stacking, marks and intervals, diff and tokens).
    - `bun test` 35/35; engine rebuilt with the rules.
    - App build: SUCCEEDED, no new warnings; lint clean.
  - **Decisions:** D56 (D02 built as picked), D57.
  - **Owner hand test (2026-10-03):**
    - Esc keeps the board (pass).
    - The board looked like it drew itself → the buddy's pen now writes every part.
    - The board came up late → it opens on arrival.
    - Labels were clipped → clamped.
  - **Owner hand test 2 (2026-10-03):**
    - Number line pen positions were wrong (reporting bug) → fixed.
    - The board looked bad → redesigned.
    - "Draw a triangle" gave a proof → `geometry` figure (D59).
    - Too fast → calmer pacing (D58).
    - Lasso answers wandered → outside dimmed + region-only prompt.
    - Lasso glow looked bad → smooth line with two glows.
    - OCR'd maths made correct marks "not found" → only words are verified.
    - Latency was 8–16 s to the first word on free Flash Lite with 7–14k-token prompts (two images + a growing session): noted, not fixed.
  - **Owner hand test 3 (2026-10-03):**
    - Most things fine.
    - "Draw a hexagon" gave maths → shape hint + `regular` polygons (D60).
    - Circle-it mid-answer → only after the answer and only if nothing was shown.
    - A line ran off the board → lines scale to fit.
    - No mark seen on the desktop although one was drawn → diagnostic log added (owner to retry).
    - `swift test` **112/112**.
  - **Owner hand test 4 (2026-10-03):**
    - Board maths was text → LaTeX typeset with SwiftMath 1.7.3 (D61).
    - Huge ellipses on equation lines → boxes for big targets.
    - Choosing the board vs geometry is a model limitation: tuned for the stronger Cline models, still working with Flash Lite.
    - `swift test` **124/124**; `bun test` 35/35; engine rebuilt; app build SUCCEEDED, no new warnings.
  - **Owner hand test 5 (2026-10-03):**
    - A wrong solution of the wrong question → pointer + crop + worked-solution context (D62).
    - Cline test: Sonnet 5.5 correct (14.9 s to first text); Flash Lite incomplete.
    - `swift test` **127/127**.
  - **Owner report 6 (2026-10-03):**
    - The Cline toggle failed every turn → session tied to the engine run (D64).
    - A Keychain prompt on every build → read via `/usr/bin/security` (D64).
    - The 15 s wait → question-aware fillers from the fast slot, with reasoning kept (D63).
    - `swift test` **131/131**.
  - **Owner report 7 (2026-10-03):**
    - Two answers at once → one answer at a time.
    - Random pointing → coordinates on the first image.
    - Missing intermediate steps → rules + 24 lines + a scrolling board.
    - Too fast → 0.82× with longer pauses.
    - Double "sure" → the filler is the acknowledgement (D65).
  - **Checks:**
    - `swift test` **108/108**; `bun test` 35/35; engine rebuilt.
    - App build SUCCEEDED, no new warnings; lint clean.
- [ ] **S11** 3 app skill packs + teaching-plugin injection (§4.2.7, §7.5)
- [x] **S12** Guided walkthroughs + everyday controls (§4.2.6, §4.3, §6.7, D67, D68), 2026-10-10
  - **Built:** plan → `step` lines; per-step capture, OCR or model locate, pen circle + number on the spoken word; completion by click/drag/shortcut/Return + tile diff; re-plan off script; hints 20/40/60 s; commands (next, skip, back, start over, stop, repeat, why); questions mid-step; step HUD (Back/Skip/Stop); recap card (copy); saved how-tos (run, copy, delete); study mode; kids mode; user memory (panel editor + `remember` lines); lasso chooser (Explain/Summarise/Translate). DEBUG row "Test walkthrough: Finder (no model)".
  - **Checks:** `swift test` 158/158 (27 new); `bun test` 35/35; engine rebuilt; app build SUCCEEDED; lint clean on new and changed lines. Plan format probed once on the free dev profile (Gemini via the SDK): parsed.
  - **Not verified (owner):** the live run on DaVinci with Cline models; completion feel; HUD placement; voice commands by speech; memory updates from conversation.
  - **Spike S7** (90 % detection over recorded sequences) not run: no recorded sequences yet.
  - **Owner hand test 1 (2026-10-10):** the Finder test and "turn on Dark Mode" (Opus) worked end to end; the Mail request and "Guide how to…" didn't become walkthroughs → D69 (task intent, adopt steps from answers, open missing apps instead of refusing, screen look while waiting). `swift test` 160/160, `bun test` 35/35, engine rebuilt, build SUCCEEDED.
  - **Owner hand test 2 (2026-10-10):** typing not noticed, circles off, engine "not smart" → D70: the model checks the live screen after every action and points every step. `swift test` 157/157, `bun test` 35/35, engine rebuilt, build SUCCEEDED. Start and check formats probed on the free dev profile (text only).
- [ ] **S13** Check chip at walkthrough end (recap done in S12) (§4.2.6, §4.3, D67)
- [ ] **S14** Sign-in screen, "under the hood" view, no usage figures (§4.7, §5.11, D66)
- [ ] **S15** Rehearsal cache + 5/5 dress rehearsals (§4.7, §13 exit criteria)

## Setup (done, not a slice)
- 2026-10-10: spec v0.2 refocused on general daily use (D67); credit usage removed from logs, docs, eval output and the S14 plan (D66).
- `AGENTS.md` rewritten (Chalk demo context); `CLAUDE.md` symlink replaced by `@AGENTS.md` (D17).
- Skills added: `.claude/skills/{slice-workflow,teaching-script,cline-sidecar,grounding-and-capture}`.
- `.gitignore`: `.claude/` → `.claude/*` + `!.claude/skills/` so skills can be committed (D16).
- `docs/DEMO_PLAN.md`, `docs/DEMO_DECISIONS.md` created.
- Not committed yet.


## Owner-requested identity overhaul — D78 (2026-10-10)

- New Chalk control panel, paper/plum/coral tokens, beacon cursor/menu icon, app icon, local 12-second onboarding introduction, captions, response cards, workspace preferences, guide cards and paper whiteboard (§3.5, §4.3, §5.4, §6.5).
- Renamed project, targets, scheme, Swift module, entry point, entitlements, analytics and presentation files. Existing installation identity/preferences and MIT notices retained.
- Checks: Debug app BUILD SUCCEEDED; ChalkCore 175/175; Sidecar typecheck clean and tests 37/37. Asset-generation script ran successfully (macOS 27 reports deprecations for APIs kept compatible with macOS 26).
- Could not verify: live permission dialogs, voice/audio, multimonitor overlay placement, and the complete visual interaction flow. App not launched; owner runs from Xcode ⌘R.
- Final validation: renamed app/unit/UI test targets compile (`TEST BUILD SUCCEEDED`, no app launch); identity audit passes; strict lint clean on rewritten UI files; plist/project validation and shell syntax pass; built bundle contains the new icon, local introduction, MIT notice and unchanged engine helper.
- Repository folder renamed to `chalk`. Moving the old DerivedData exposed stale Sparkle artifact paths; validation rerun with fresh `build/IdentityValidation` rather than changing dependency configuration. Existing Xcode caches may need reset after opening the relocated project.


## Runtime identity follow-up — D79 (2026-10-10)

- Fixed missed Core Animation triangle/blue ink. Active pen, annotation roles, learner trails, image ink and label chips now match Chalk; listening/processing have plum-backed coral indicators (§5.5, §5.6).
- New headless Swift regression executable checks all six role/token colors and beacon geometry. Extended identity audit covers the active renderer and rejects inherited blue hex colors. Both PASS; ChalkCore 175/175.
- Cline SDK browser sign-in completed as amey.taksali@gmail.com; saved metadata and owner-only credential permissions verified without exposing tokens. No real model calls.
- Could not verify: live drawing contrast across apps, multimonitor placement, animation feel or voice. Owner runs the rebuilt Chalk scheme from Xcode; old already-running builds must be restarted.
- App and renamed test targets: TEST BUILD SUCCEEDED. Strict lint clean across modified renderer/theme/overlay files; identity and headless ink/geometry regressions pass. App not launched.


## Regression audit — D80

- Fixed white-on-paper native LaTeX equations; whiteboard/math/geometry and walkthrough files retained. Verified preserved controller logic and installed rules/helper.
- Added content-free unified dispatch diagnostics to make a failed walkthrough request traceable outside Xcode.
- Walkthrough failure not reproduced: existing log has no walkthrough-start event and no request/parser detail. Need exact failed utterance or owner Xcode console; no paid model call or app launch performed.
- Validation: TEST BUILD SUCCEEDED; ChalkCore 175/175; strict lint clean on both modified Swift files; identity/wiring audit PASS; no whitespace errors. Live missed-walkthrough cause remains unconfirmed.


## Live Logs — D81

- Menu-bar Live Logs opens opt-in live diagnostic window; filter, pause/resume, follow, copy, clear; reader stops when closed. No screenshot/model calls or disk writes.
- Broader content-free instrumentation: engine, dictation, capture/perception, request routing, script/whiteboard outcomes. Existing walkthrough/grounding/sync/latency events included.
- Headless buffer test PASS: chunk boundaries, Unicode, bounded retention, sensitive filtering, clear and oversized input. macOS log-stream command smoke test PASS. Initial app/test build SUCCEEDED.
- Could not verify: interactive viewer controls and live event rendering inside the app; owner runs from Xcode. No reasoning-proposal changes implemented.
- Final validation: TEST BUILD SUCCEEDED; ChalkCore 175/175; live-buffer headless test and identity audit PASS; strict lint clean on new viewer/buffer and formatted touched files; Sidecar/ChalkCore source unchanged.


## Adaptive agent experiment — D82

- Implemented optional single-action adaptive planning, Swift revision guards, persistent Guide, bounded Strategist/Diagnostic/Verifier roles, decision cards, confirmed consequential actions, refreshed evidence, local recovery and explicit legacy fallback. Existing executor and whiteboard remain.
- Headless coordinator tests cover stale revisions, workflow isolation, bounded recovery/context, strict proposals, invalid target/shortcut, decision matching, consequential confirmation and continuation history. Stub SDK test verifies persistent Guide and isolated diagnostic calls; rule injection includes internal override.
- Checks so far: 184 core tests PASS, 38 sidecar tests PASS/typecheck clean, rebuilt helper, app/test build SUCCEEDED; strict lint and identity audit PASS.
- Manual checklist: docs/ADAPTIVE_GUIDANCE_TESTING.md. Could not verify real models' schema adherence, speech/pointing feel, decision voice matching, actual recovery accuracy/latency, secure-input transitions or multimonitor placement. No real-model requests or app launch by agent.
- Final validation: core 186/186 (11 new adaptive tests), sidecar 38/38/typecheck clean (one new role-isolation contract), TEST BUILD SUCCEEDED, strict lint clean on adaptive files, identity/log-buffer checks PASS. Bundled helper SHA-256 matches rebuilt Sidecar helper.


## Developer text input — D83

- Added persistent off-by-default Developer text input toggle/card to menu-bar panel, text field with Enter/Send, validation and setup error. Same capture/ask/audio/drawing path, no microphone recording.
- Headless normalization checks PASS; initial TEST BUILD SUCCEEDED; core 186/186. Pipeline source assertions verify normal ask/capture timing, no STT start and no transcript persistence.
- Could not verify: live Return/button handling, audio response, front-app focus/cursor-display capture, adaptive choices/commands through typing. Owner runs from Xcode; no app launch or paid model probe.


## D84 — Single rolling planner, continuity and latency fixes

- Consolidated new guidance to persistent rolling Guide plus locally validated conditional candidates. Removed legacy planning toggle/fallback; retained saved executor. Combined strategy/first-action reply; diagnosis escalates after local repair.
- Shared ledger and focused current evidence, actual aborting deadlines, retained send-session ID, false-undo/shortcut/static-completion removal, stricter typing/predicates, one verifier lane, immediate step marks/old-speech interruption.
- AGENTS.md handoff updated with sole-planner architecture and new context. Tests added for session continuity (including compiled helper), stuck stream/deadline/cancel, partial typing, context, compound predicate rejection, candidate grounding/risk and shared evidence privacy.
- Could not verify: real-model schema/candidate quality, real first-action/inter-step latency, actual typing transitions, pointer-speech feel, app-switch and video screen stability. Agent did not launch app or run paid probes. Owner retests flight/Mail/whiteboard.
- D84 final automated validation: 199/199 core tests (13 new rolling/deadline tests including compiled-helper continuity), 38/38 sidecar tests, typecheck clean, TEST BUILD SUCCEEDED; strict lint clean; identity, developer-text and live-buffer checks PASS; helper hash matches rebuilt Sidecar binary. Final review clears candidates on Skip/Back/Start Over and refreshes screen evidence after second-recovery diagnosis.


## D85 — Command Space / Spotlight outcome detection

- Explicit system UI outcome check fixes missing key-event path; focused visible Spotlight field confirmed twice. Spotlight tree supplies subsequent typing context.
- Core 201/201; initial TEST BUILD SUCCEEDED; final build/lint pending review.
- Could not verify: actual Spotlight window owner/focus shape on macOS 27, completion after Command Space without monitor event, close-with-Escape noncompletion, follow-up app search/Return. Owner manually tests; no app launch/model probe.
- Final validation: TEST BUILD SUCCEEDED; strict lint clean on changed Spotlight/controller and pure tests; identity audit PASS; whitespace check clean. Core tests 201/201. Live macOS Spotlight flow still requires owner verification.

## D86 multi-agent guidance (2026-10-10)
- Built ChalkCore `Guide/`: coordinator, helper prompts and parsers, prediction check, ledger. Rewrote `Chalk/WalkthroughController.swift` as the coordinator's app side (observe, present, watch, stream helper calls).
- Removed the D84 rolling Guide code and its rule overrides.
- Added `Eval/guide-sim` (use-case simulator) with 7 scenarios in `Eval/usecases`: dark mode, Mail write and send, Mail not open, cheapest flight, flights done the user's own way with "I'm lost", Canva invitation, DaVinci warmer with no tree.
- Simulator iterations on the free dev profile fixed several problems:
  - self-naming done predicates;
  - loose "To"/"October" matches;
  - no local signal for clicks that changed the screen;
  - missed Return shortcut steps;
  - separate click-the-field steps;
  - typed text not counting as screen text;
  - going past the goal;
  - an estimate that drifted upward.
- Final simulator run: 7/7 goals reached, 0 wrong circles. A matching prediction shows the next step 0.6–0.9 s after the user acts; a planner step takes ~2–3 s on flash-lite. Remaining stalls came from free-tier rate limits.
- Checks: core tests 196/196 (10 new), engine tests 38/38 (source and binary), app build SUCCEEDED.
- **Could not verify:**
  - real Claude latency and accuracy (needs `--profile demo`);
  - real-app behaviour of settling, OCR words in DaVinci, ⌘Space/Spotlight, and the click-on-circle detection with real windows;
  - speech timing of heads-ups.
  The owner hand test is in `docs/ADAPTIVE_GUIDANCE_TESTING.md`.
