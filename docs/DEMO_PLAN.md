# Demo plan: Hackathon Demo Cut (§4.7)

**Ordering.** Slices follow the §4.5 dependency spine (capture + OCR + marks → grounding → Teaching Script → renderer ⇄ TTS timing → walkthrough), with the **riskiest unknowns first**:
1. Sidecar under bun (S01).
2. Cline vision and latency (S02), and the voice loop (S04).
3. Grounding accuracy (S05, S08).

S00 is the mandatory hygiene fix before any feature work (§0.3, §0.13).

**Exit criteria** (§13 "Hackathon demo" row):
- the 3-minute demo script (§4.7) runs 5/5 times on the demo Mac;
- first word ≤ 2 s p50;
- no leftover marks.

**Spikes that gate the demo** (§15):

| Spike | Slice |
|---|---|
| S0 | S01 |
| S1, S1b, S3 | S02 |
| S5 | S04 |
| S2 | S05 |
| S4 | S06 |
| S6 | S07 |
| S7 | S12 |

S8 (STT technical vocabulary) is **not** a demo gate (not in §4.7); run it opportunistically in S04. S1b only matters for the fallback adapter.

Every slice follows `.claude/skills/slice-workflow`. "Owner verifies" items are things the agent cannot check headlessly. Decision IDs refer to `docs/DEMO_DECISIONS.md`.

---

## S00: Hygiene: overlay fill, automatic termination, macOS 26 target
- **Goal.** Remove the full-screen near-transparent overlay fill that likely blackens third-party captures. Stop macOS from auto-terminating the windowless app. Raise the deployment target to macOS 26.
- **Spec.** §0.2, §0.3, §0.13, §6.5, §6.6, §11.4 P-BLACKCAP / P-AUTOTERM, header (macOS 26). D11, D12.
- **Files.**
  - `Chalk/ScreenBeaconOverlay.swift`: delete `Color.black.opacity(0.001)` at `BlueCursorView.body` (line ~187); set `sharingType = .none` in `ScreenBeaconOverlay.init` (§6.6). **Keep `.screenSaver` level (D12).**
  - `Chalk/ChalkApp.swift`: `ProcessInfo.processInfo.disableAutomaticTermination("Chalk is running")` in `applicationDidFinishLaunching` (§0.2).
  - `Chalk.xcodeproj/project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET` 14.2 → 26.0 in all configs (D11). Committed normally; signing is in `Config/` (D28).
- **Acceptance (agent).**
  - `xcodebuild … build` succeeds.
  - `! grep -rn 'opacity(0.001)' Chalk/`.
  - `grep -n disableAutomaticTermination Chalk/ChalkApp.swift`.
  - `grep -c 'MACOSX_DEPLOYMENT_TARGET = 26.0' Chalk.xcodeproj/project.pbxproj` = 4 (project Debug/Release + unit-test target Debug/Release; app and UI-test targets inherit from the project), and no `14.2` remains (D33).
- **Owner verifies.**
  1. Run from Xcode: the blue cursor still renders, follows, and flies to a point target.
  2. With the overlay visible, ⇧⌘4 → Space → click a Safari window: the capture shows Safari, not black.
  3. Same for a Loom window share and a Zoom window share.
  4. Leave the app idle with no panel open for 10 min: still running (Activity Monitor).
  5. The TCC prompts didn't reset (D07).
- **Fallback.**
  - If SwiftUI stops rendering without the fill: use `Color.clear` (a fully transparent layer).
  - If captures are still black: pull the S6 level experiment (S07) forward and try `.statusBar + 1`.

## S01: Spike S0: `tutor-engine` sidecar on ClineCore under bun ⚠ riskiest
- **Goal.** Prove the pinned `@cline/sdk` ClineCore runs as a `bun build --compile` binary that speaks the §7.3 NDJSON protocol, with built-in tools disabled, a `createTool` round trip, and abort/steer, all tested against a **stub provider**.
- **Spec.** §7.3 (process model, IPC, tools), §7.5 (rules location), §11.1 (stub provider), §15 S0, §16.2. D09, D10, D20, D22.
- **Files (new).**
  - `Sidecar/package.json`: `"@cline/sdk": "0.0.90"` exact (registry-verified, D31); no `trustedDependencies`; scripts `typecheck`, `test`, `build:bin`.
  - `Sidecar/bun.lock` (**committed**), `Sidecar/tsconfig.json`.
  - `Sidecar/src/index.ts`: stdio NDJSON loop for `ping`, `prewarm`, `start`, `send` (`delivery`), `abort`, `tool_result`, `usage`.
  - `Sidecar/src/core.ts`: `ClineCore.create`; `toolPolicies {enabled:false}` for `run_commands`, `editor`, `apply_patch`, `read_files`, `search_codebase`, `fetch_web_content` and team/spawn tools; `CLINE_DIR` from env.
  - `Sidecar/src/tools/proxy.ts`: `createTool` definitions that emit `tool_call` and await `tool_result`. Demo set: `create_flashcard`, `advance_step`, `mark_step_done`.
  - `Sidecar/model-routing.json`: §7.4 slots (D22).
  - `Sidecar/test/stub-provider.ts`: OpenAI-compatible SSE server with canned NDJSON scripts, delays, error modes, and capture of the request `tools`.
  - `Sidecar/test/contract.test.ts`.
  - `Sidecar/scripts/s0-coldstart.sh`.
- **Acceptance (agent).**
  - `bun run typecheck` and `bun test` pass, covering:
    1. start → `session` → `text` deltas → `done`;
    2. `abort` stops the stream within ≤ 100 ms (measured in the test);
    3. a `steer` send reaches the running turn;
    4. a `tool_call` → `tool_result` round trip;
    5. the stub sees **none** of the built-in tools in the request;
    6. stub errors map to `ev:"error"` kinds;
    7. SDK telemetry is off: no outbound connections except the stub during the run (D32).
  - `bun run build:bin` produces `Sidecar/dist/tutor-engine`.
  - `env -i PATH=/usr/bin:/bin Sidecar/dist/tutor-engine` answers `ping` with no Node on PATH.
  - `s0-coldstart.sh` reports p50 launch → first `pong` ≤ 600 ms over 10 runs.
- **Owner verifies.**
  - Notarize the binary with the Developer ID, if available.
  - Optionally run it on a clean macOS 26 VM.
  - Which TCC permission the listen-only keyboard tap needs on macOS 26/27 (D20): revoke Accessibility, grant only Input Monitoring, and check that ⌃⌥ still fires.
- **Fallback.**
  - SDK fails under bun → embedded Node 22 runtime launching `dist/index.js` (S0 plan B).
  - ClineCore unusable → `@cline/agents` `Agent`.
  - Neither works → Cline API adapter (text-only until S1b passes).
  - The stub providerId/`baseUrl` route isn't discoverable from SDK types → log a decision and stub at the `fetch` layer (`ClineCore.create({fetch})`).

## S02: Spikes S1 + S1b + S3: Cline vision and latency with real credits
- **Goal.** Confirm screenshots reach each slot candidate through Cline, detect the non-vision placeholder, and measure TTFT and first-`speak`-line latency to fill `model-routing.json`.
- **Spec.** §7.4 (slots, capability guard), §14a/b, §15 S1/S1b/S3, §11.3. D10, D22.
- **Files (new).**
  - `Eval/fixtures/vision-probe/*.png`: 3 labelled marks + a random 4-digit number per image.
  - `Sidecar/scripts/probe-vision.ts`: per model ID, via the sidecar protocol.
  - `Sidecar/scripts/probe-cline-api.ts` (S1b, `image_url` parts).
  - `Sidecar/scripts/probe-latency.ts` (50 runs per slot model).
  - `Eval/results/S02-*.md`.
- **Acceptance (agent).** The scripts run and print tables; exit non-zero below thresholds:
  - S1: 3/3 labels per vision candidate; the placeholder is detected for one text-only model.
  - S3: fast TTFT ≤ 600 ms p50; teaching ≤ 900 ms; first `speak` line ≤ 1.1 s.
  - The results file is committed and `model-routing.json` is updated.
- **Owner verifies.** Supply credentials or sign in (D10) and approve spending credits (~150 short calls).
- **Fallback.**
  - Re-assign slots.
  - Shorten prompts; put the injected context in cached prefixes (§14b).
  - Plan the fast-slot acknowledgement ("let me look…") for S04.
  - S1b fails → the adapter stays text-only.

## S03: Teaching Script v1 parser, validator and repair (ChalkCore)
- **Goal.** A streaming NDJSON parser that turns text deltas into validated actions, with the §6.4 recovery rules and the demo primitive allowlist.
- **Spec.** §6.4, §4.2.1 (Demo column, D01), §4.2.3 (figures, D02), §11.2 (malformed ≤ 2%). Skill: `teaching-script`.
- **Files (new).**
  - `Packages/ChalkCore/Package.swift`: swift-tools 6.x, `.macOS(.v26)`, one library target `ChalkCore`, one test target (D08).
  - `Packages/ChalkCore/Sources/ChalkCore/TeachingScript/{Actions,TargetDescriptor,StreamingScriptParser,ScriptValidator}.swift`.
  - Tests.
  - pbxproj: link `ChalkCore` as a local package to the app target (D08).
- **Acceptance (agent).** `swift test --package-path Packages/ChalkCore`:
  - the §6.4 example split at every byte boundary yields identical actions;
  - interleaved plain text becomes `speak`;
  - an unknown `type` is dropped and logged;
  - non-demo primitives (`spotlight`, `bracket`…) are dropped;
  - `cite` is dropped (D01/D02 scope);
  - 2 KB without a newline flushes as speech;
  - code fences and trailing commas are repaired.
  - `xcodebuild … build` passes with the package linked.
- **Owner verifies.** The project still opens in Xcode, and ⌘R works with the package dependency.
- **Fallback.** If linking via pbxproj is fragile, the owner adds the local package in Xcode (File › Add Package Dependencies › Add Local…) and the agent stages only that diff.

## S04: Voice loop end to end (speak-only) + spike S5
- **Goal.** Hold ⌃⌥ → SpeechTranscriber → sidecar (teaching slot) → streamed script → AVSpeechSynthesizer speaking each `speak` group as soon as its line completes; barge-in stops speech and steers or aborts. Measure §11.3 latencies.
- **Latency mitigations (D43):** capture + OCR at key-down (§7.6); JPEG model image instead of PNG; an immediate spoken acknowledgement while the answer streams. Target: first word ≤ 2 s p50 (§13).
- **Spec.** §7.2, §7.3 (supervision, prewarm), §7.4 (router rules, guard), §7.5 (`.clinerules`), §7.6 (STT, TTS, barge-in), §4.2.4, §11.3, §15 S5. Decisions D13, D14, D24.
- **Files.**
  - **New:**
    - `Chalk/TutorEngineClient.swift`: `Process` launch, NDJSON framing, ping only while active, restart with backoff, retry once, `prewarm` on the first press.
    - `Chalk/SpeechService.swift`: SpeechAnalyzer + SpeechTranscriber, `AssetInventory` install, volatile/final.
    - `Chalk/VoiceOut.swift`: AVSpeechSynthesizer per `speak` group, `stopSpeaking(at: .word)`.
    - `Packages/ChalkCore/Sources/ChalkCore/Routing/ModelRouter.swift`: §7.4 rules, vision allowlist.
    - `Sidecar/resources/clinerules/00-teacher.md`, `10-teaching-script.md`, `20-grounding.md`, `30-safety.md`.
    - Latency signposts plus one log line per turn.
  - **Modify:**
    - `CompanionManager.swift`: replace `sendTranscriptToClaudeWithScreenshot` with the engine path; start capture at key-down.
    - `BuddyDictationManager.swift`: use `SpeechService`; drop provider factory use.
    - `BuddyTranscriptionProvider.swift`.
    - `ChalkAnalytics.swift`: no-op (D14).
  - **Delete (D13):** `AssemblyAIStreamingTranscriptionProvider.swift`, `OpenAIAudioTranscriptionProvider.swift`, `BuddyAudioConversionSupport.swift`, `ElevenLabsTTSClient.swift`, `ClaudeAPI.swift`, `OpenAIAPI.swift`, `ElementLocationDetector.swift`, `worker/`, and Info.plist `VoiceTranscriptionProvider`.
- **Acceptance (agent).**
  - `swift test`: router rules table; vision guard refuses a text-only model for image turns (P-NOVISION); NDJSON client framing tested against the compiled sidecar + stub (spawned from the test): start → speak lines delivered in order, abort, restart after `kill -9` with one retry (P-SIDECAR).
  - `! grep -rnE 'api\.anthropic\.com|elevenlabs|assemblyai|api\.openai\.com|posthog\.com|submit-form' Chalk worker 2>/dev/null`.
  - `xcodebuild … build`.
- **Owner verifies (S5).**
  - 30 questions on 3 apps; read the per-turn log: key-up → first spoken word ≤ 1.5 s p50 / 2.5 s p95 (demo exit needs ≤ 2 s p50).
  - STT quality; voice quality; barge-in feel (≤ 120 ms silence).
  - Use wired or built-in audio on stage (D24).
  - Optional S8 vocabulary check.
- **Fallback.**
  - Fast-slot acknowledgement pre-speak while teaching streams (§15 S5 plan B).
  - Smaller images.
  - Window-scoped crop only.

## S05: Capture, Vision candidates, set-of-marks + spike S2 harness
- **Goal.**
  - Native-resolution capture of the cursor display plus a frontmost-window crop.
  - Vision OCR and rectangles → ≤ 120 marks, then the marks image and marks list sent with each turn.
  - An offline grounding harness over golden screenshots.
- **Spec.** §6.2 (a)(b)(c), §6.3, §6.8, §10.2 (secure input, window-scoped), §15 S2. Skill: `grounding-and-capture`.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/ScreenSpace/ScreenSpace.swift`: the v1 math from `CompanionManager` ~640–677, centralized.
    - `…/Perception/{Candidate,MarkSelection}.swift`: merge, NMS, prioritization, cap.
    - `Chalk/CaptureService.swift`: SCK native + window crop + ≤1568 downscale; keeps own-window exclusion.
    - `Chalk/PerceptionService.swift`: Vision requests.
    - `Chalk/MarksImageRenderer.swift`.
    - `Eval/grounding/` CLI target (in ChalkCore as an executable product) and `Eval/golden/<app>/*.png` + `targets.json`.
  - **Modify:** `CompanionScreenCaptureUtility.swift` (superseded; remove once unused).
- **Acceptance (agent).**
  - `swift test`: ScreenSpace round trips for negative-origin secondary displays, 1×/2× mixes and portrait; the v1 characterization case reproduces v1 output; NMS and cap tests.
  - The harness runs offline: candidate recall ≥ 92% on the golden set.
  - With approval, a model-pick run (credits) reports hit rate ≥ 85% on the 40-target set (§6.8 demo gate), i.e. at most 6 misses.
- **Owner verifies.**
  - Capture the golden set: **40 targets** from the exact demo screens, about 20 in the hero app (Figma or Blender, D06), 10 in the scanned PDF in Preview and 10 in VS Code. Use a few screenshots with several targets each, and label target boxes with the labelling helper, which prints coordinates (D30). About 15 minutes.
  - Approve the credit spend.
  - Confirm no screenshot is written to disk.
- **Fallback.**
  - Add contours and saliency candidates.
  - Enable the two-stage zoom (d) by default for icon targets.
  - Default to "can you circle it?" below the confidence threshold.

## S06: Annotation renderer, lifecycle registry, voice sync + spike S4
- **Goal.**
  - The 10 demo primitives (D01) in hand-drawn style on `CAShapeLayer`, in the existing per-display overlays.
  - The lifecycle registry with the ink budget and cleanup triggers.
  - Strokes that start when `willSpeakRangeOfSpeechString` reaches their anchor.
- **Spec.** §4.2.1, §4.2.2, §4.2.4, §5.5, §5.6, §6.5, §11.2 (sync), §11.4 P-LEFTOVER / P-IDLECPU, §15 S4. D18, D19. Skill: `teaching-script`.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Annotation/{RoughStrokeGenerator,LifecycleRegistry,AnchorMapper}.swift`.
    - `Chalk/AnnotationRenderer.swift`: layer groups by z-order; `strokeEnd` animations; no display link.
    - `Chalk/AnnotationColorRoles.swift`: extends `DS` with §5.6 roles.
  - **Modify:**
    - `ScreenBeaconOverlay.swift`: host the renderer layer; move ghost-cursor `point` + `ring` onto the script path; replace the permanent 60 Hz `startTrackingCursor` timer with tracking only while visible or animating (P-IDLECPU).
    - `VoiceOut.swift`: delegate range callbacks → anchors.
    - Esc and talk-key cleanup.
- **Acceptance (agent).** `swift test`:
  - P-LEFTOVER property test (random scripts × random cancel points → registry empty except board);
  - budget never > 3 emphasis + 1 spotlight;
  - transient fade at 2.0 s;
  - speech-bound fade on group end;
  - anchor offsets are correct after marker stripping;
  - rough paths are deterministic per seed;
  - replay determinism with recorded timing events.
  - `xcodebuild … build`.
  - A log parser (`Eval/s4-sync.sh`) computes stroke-onset − anchor-word delta from the app log.
- **Owner verifies (S4).**
  - Run the debug "S4 sync script" (3 sentences, 5 anchors) from the panel; send the log; p95 ≤ 150 ms.
  - Strokes look hand-drawn and legible on light and dark.
  - No dropped frames with 10 marks.
  - Idle CPU ≤ 0.5% in Activity Monitor with nothing visible.
- **Fallback.**
  - Estimated-WPM timeline when range callbacks are unreliable.
  - Simpler strokes (single pass) if frames drop.

## S07: Capture coexistence + spike S6
- **Goal.** Annotations stay out of third-party captures, nothing ever goes black, overlays hide for ⇧⌘3/4/5, and overlays rebuild on display changes. Decide the overlay level (D12).
- **Spec.** §6.5, §6.6, §11.4 P-BLACKCAP / P-SCRNSHOT / P-DISPLAYS, §15 S6. Skill: `grounding-and-capture`.
- **Files.**
  - **Modify:**
    - `GlobalPushToTalkShortcutMonitor.swift`: detect ⇧⌘3/4/5 in the O(1) listen-only callback (P-HOTKEY).
    - `ScreenBeaconOverlay.swift` / `ScreenBeaconOverlayManager`: hide 10 s on the chord; rebuild on `didChangeScreenParametersNotification`; level per the S6 result.
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Hotkeys/ChordMatcher.swift`.
    - `Eval/S6-capture-matrix.md` (results table).
- **Acceptance (agent).**
  - `swift test`: chord matcher (3/4/5 with modifiers, no false positives on ⌘3).
  - `xcodebuild … build`.
  - `! grep -rn 'opacity(0.001)'`.
- **Owner verifies (S6 matrix).**
  - With marks visible, capture via ⇧⌘3, ⇧⌘4 window, ⇧⌘5 (still + recording), QuickTime, Loom (window + screen), Zoom/Meet share, OBS.
  - Expect: app content visible, never black; marks absent.
  - Try `.screenSaver` vs `.statusBar + 1`, and check that menus and the ⇧⌘5 UI stay usable.
- **Fallback.** Hide the overlays whenever another capture is detected or the chord is pressed; document tool-specific exceptions.

## S08: Target resolution, verification pass, zoom fallback, ghost point
- **Goal.** Resolve script targets (`mark` → `text` → `region` → `relative` → `px`) to overlay coordinates, verify after drawing, fall back to the zoom pass or "can you circle it?".
- **Spec.** §6.2 (d)(f), §6.4 (descriptors), §7.4 rules 4–5, §5.10 (low-confidence copy). Skills: `grounding-and-capture`, `teaching-script`.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Grounding/{TargetResolver,FuzzyTextMatch,VerificationCheck}.swift`.
    - `Chalk/GroundingService.swift`: verification re-capture of a 300×300 pt crop + re-OCR; zoom pass via the grounding slot.
  - **Modify:** `AnnotationRenderer.swift` (resolve before drawing; downgrade to speech-only on failure).
- **Acceptance (agent).**
  - `swift test`: resolution order on fixture mark sets; `near`/`within` disambiguation; `px` flagged low-confidence; verification accepts and rejects on fixture crops; escalation after 2 failures.
  - With approval, an end-to-end harness run on the 40-target golden set reports ≥ 85% hit (≤ 6 misses).
- **Owner verifies.** Pointing and drawing land on the right things in the 3 demo apps (visual accuracy).
- **Fallback.** Lower the confidence threshold to prefer "circle it"; add more candidate types.

## S09: Spatial context: lasso "explain this region"
- **Goal.**
  - Hold ⌃⌥ + drag draws a violet paint trail on the active display.
  - A closed loop becomes a lasso region whose native-res crop is attached to the turn.
  - Release without speech = "explain this region".
- **Spec.** §4.2.5 (lasso only in the demo, §4.7), §5.2 (D18), §10.1. Skill: `grounding-and-capture`.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Spatial/LassoClassifier.swift`: closed-loop detection, bounding region.
    - `Chalk/DrawChordPanel.swift`: mouse-accepting **only while the chord is held**, active display only.
  - **Modify:** the hotkey monitor (drag-while-chord); the context assembly (crop + "learner circled region R").
- **Acceptance (agent).**
  - `swift test`: lasso vs open stroke; region bounds; tiny strokes ignored.
  - `xcodebuild … build`.
- **Owner verifies.**
  - Gesture feel.
  - After release the panel is gone and clicks pass through (click-through invariant).
  - Works on a second display.
- **Fallback.** A rectangle drag-select instead of a freeform lasso.

## S10: Whiteboard: `numberline` + `math_steps` (D02)
- **Goal.** A non-activating whiteboard panel rendering the declarative `numberline` and `math_steps` figures with progressive reveal on anchors and highlighted changed spans.
- **Spec.** §4.2.3, §4.2.9, §4.2.4 (progressive reveal), §5.11 (wireframe). D02, D25.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Figures/{NumberLineLayout,MathStepsDiff}.swift`.
    - `Chalk/WhiteboardPanel.swift`.
    - `Chalk/FigureRenderer.swift`.
- **Acceptance (agent).**
  - `swift test`: numberline tick/label layout; math-steps changed-span diff (e.g. `x = 0.999…` → `10x = 9.999…`).
  - Validator accepts `figure` for these two kinds only.
- **Owner verifies.** Demo script step 3 ("why 0.999… = 1") looks right and reveals in sync.
- **Fallback.** Unicode/plain-text math lines with highlighted diffs (no LaTeX renderer, D25); or drop `math_steps` if D02 is overruled.

## S11: App skill packs (3) + teaching-plugin injection
- **Goal.** DaVinci Resolve (hero, D06), Preview PDF and VS Code packs in Cline `SKILL.md` format, detected by bundle ID and window title, and injected by the teaching plugin's `before_agent_start` hook along with the marks list.
- **Spec.** §4.2.7, §7.5 (plugin, rules), §4.7 (3 packs). D05, D06. Skill: `cline-sidecar`.
- **Files.**
  - **New:**
    - `Sidecar/resources/skills/app-davinci-resolve/SKILL.md` (with `## Regions` for the Color page and `## Workflows` holding colour-grade hints for the planner, D67), `app-preview-pdf/SKILL.md`, `app-vscode/SKILL.md`.
    - `Sidecar/src/plugin-teaching.ts`.
    - `Packages/ChalkCore/Sources/ChalkCore/SkillPacks/SkillPackMatcher.swift`.
- **Acceptance (agent).**
  - `bun test`: frontmatter is valid (`name` = dir, `description` ≤ 1024 chars); the stub receives the matched pack body and marks list in the prompt; the allowlist hook blocks a non-allowlisted tool.
  - `swift test`: bundle ID/title → pack mapping.
- **Owner verifies.** Pack content accuracy for the hero app version on the demo Mac.
- **Fallback.** Inline the pack text into the `start.context` prompt from Swift if plugin hooks misbehave.

## S12: Guided walkthrough + spike S7
- **Goal.** "Guide me how to colour grade this" (§4.2.6): a 5–7 step plan generated by the deep slot from the screen and the DaVinci pack (D67), streamed one step per line:
  - step badge, ghost point and ring per step;
  - completion detected without AX;
  - hint rung 1 (D04);
  - re-plan from the current screenshot on an off-script action;
  - questions mid-step answered on the same session, then back to the waiting step;
  - `advance_step` / `mark_step_done` tools.
- **Spec.** §4.2.6, §6.7, §4.7, §11.3 (step feedback ≤ 1.2 s p95), §15 S7. D04, D06, D67.
- **Files.**
  - **New:**
    - `Packages/ChalkCore/Sources/ChalkCore/Walkthrough/{WalkthroughState,TileDiff,CompletionScorer}.swift`.
    - `Chalk/WalkthroughEngine.swift`: the listen-only mouse/key tap is installed **only while a step is waiting** and torn down after; 2 Hz frontmost-window capture **only while waiting**; OCR of changed tiles; fast-slot confirm for scores 0.5–0.8.
  - **Modify:** the HUD (step text, progress dots, "watching for your click" indicator).
- **Acceptance (agent).** `swift test`:
  - scorer thresholds (≥ 0.8 complete, 0.5–0.8 confirm, < 0.5 hint);
  - 300 ms stability;
  - ≤ 1 auto-advance per 1.5 s;
  - tile-diff on fixture before/after images;
  - state survives pause/resume in memory.
  - An S7 replay harness over recorded screenshot sequences + event logs reports ≥ 90% correct detection and ≤ 1 false advance per 50.
- **Owner verifies.**
  - Record the S7 sequences (3 workflows × 5 steps) in the hero app.
  - Live run feel.
  - The input tap indicator appears only while waiting.
- **Fallback.** Use the fast-slot confirm more often; manual "next" via voice ("done").

## S13: Walkthrough recap + check chip
- **Goal.** At the end of a walkthrough, show the recap card (steps with shortcuts, copyable as text, §4.2.6 step 9) and offer the `check` question chip with `wait_for_user`; the user's spoken answer becomes the next turn (D03). Flashcards are cut (D67).
- **Spec.** §4.2.6, §4.3, §4.7, §6.4. D03, D67.
- **Files.**
  - **Modify:** HUD (chip, recap card); `ChalkControlPanel.swift` (saved how-to row).
- **Acceptance (agent).** `swift test`: recap text from a finished walkthrough state; `check` + `wait_for_user` sequencing in the parser and timeline.
- **Owner verifies.** Chip and recap legibility.
- **Fallback.** Speak the question only.

## S14: Sign-in screen, "under the hood" view
- **Goal.**
  - Replace the video/email onboarding with a single Cline sign-in + permissions screen (D15).
  - Panel rows for the model slots in use and the privacy line "one screenshot, sent once, nothing stored" (demo script step 5). No credit, token or cost figures (D66).
- **Spec.** §4.7, §5.11, §7.3 (auth), D10, D15, D66.
- **Files.**
  - **Modify:** `ChalkControlPanel.swift` (remove email, model picker, DM button; add sign-in and slots rows); `CompanionManager.swift` (bypass the video onboarding and FormSpark).
  - **New:** sidecar `auth` op emitting the browser URL (if SDK OAuth is used, D10).
- **Acceptance (agent).** `xcodebuild … build`; no usage, token or cost string in the panel.
- **Owner verifies.** The real OAuth sign-in on the demo Mac.
- **Fallback.** API-key entry field stored in the Keychain.

## S15: Rehearsal cache + dress rehearsal
- **Goal.** A demo-only replay of the last good script per step (compiled only with `CHALK_DEMO_REHEARSAL`, D21), plus 5 full runs of the §4.7 demo script.
- **Spec.** §4.7 (risk controls, demo script), §13 exit criteria, §11.3.
- **Files.** **Modify:** `TutorEngineClient.swift` (record/replay behind `#if CHALK_DEMO_REHEARSAL`). **New:** `docs/DEMO_RUNBOOK.md` (setup checklist: audio route, displays, Cline sign-in, prewarm).
- **Acceptance (agent).**
  - A Release build contains no rehearsal symbols (`nm`/`strings` check).
  - Debug build with the flag replays a recorded script.
- **Owner verifies.** 5/5 clean runs of the 3-minute script; first word ≤ 2 s p50 (from logs); zero leftover marks.
- **Fallback.** Cut demo segment 4 (lasso) or 3 (whiteboard) if unstable.
