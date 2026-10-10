// Spike S3 (§15, §11.3): are the slot models fast enough to feel like talking? For each slot's
// model, N runs of a realistic turn (a screenshot plus a learner question, answered in Teaching
// Script NDJSON) through tutor-engine, measuring:
//   TTFT: request sent → first text delta
//   first speak: request sent → first complete {"type":"speak",...} line (what TTS can start on)
// Pass (§15 S3): fast TTFT p50 ≤ 600 ms; teaching TTFT p50 ≤ 900 ms and first speak p50 ≤ 1100 ms.
// One warm-up turn per model is not counted (the app prewarms, §7.3).
//
// Usage: bun Sidecar/scripts/probe-latency.ts [--profile demo] [--slots fast,teaching] [--runs 50]
//                                             [--models slot=model,...] [--delay-ms 0]
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveSlotModel } from "../src/routing";
import { EngineClient, option, percentile, pngDataUrl, type TurnResult } from "./engine-client";

const REPO_ROOT = join(import.meta.dir, "..", "..");
const profile = option("profile", "demo");
const slots = option("slots", "fast,teaching").split(",") as ("fast" | "teaching" | "grounding" | "deep")[];
const runs = Number(option("runs", "50"));
const delayMs = Number(option("delay-ms", "0"));
const modelOverrides = Object.fromEntries(
    option("models", "")
        .split(",")
        .filter(Boolean)
        .map((pair) => pair.split("=") as [string, string]),
);
const THRESHOLDS: Record<string, { ttftP50?: number; firstSpeakP50?: number }> = {
    fast: { ttftP50: 600 },
    teaching: { ttftP50: 900, firstSpeakP50: 1100 },
};

// A real-size screenshot (the synthetic design app, ≤ 1568 px like §6.2 a).
const screenshotPath = join(mkdtempSync(join(tmpdir(), "chalk-latency-")), "screen.png");
const resize = Bun.spawnSync(["sips", "-Z", "1568", join(REPO_ROOT, "Eval", "pointing", "fixtures", "synthetic-editor.png"), "--out", screenshotPath], {
    stdout: "ignore",
    stderr: "pipe",
});
if (resize.exitCode !== 0) throw new Error(`sips failed: ${resize.stderr}`);
const screenshot = pngDataUrl(screenshotPath);

const PROMPT = [
    "The learner asked, out loud: \"how do I export this design?\"",
    "Answer as a patient teacher, in Teaching Script NDJSON: one JSON object per line and nothing else.",
    'Line 1 must be {"type":"speak","group":"g1","text":"<one short spoken sentence>"}.',
    'Then you may point with {"type":"point","target":{"text":"<label on screen>"}} and add more speak lines.',
    'Finish with {"type":"end"}.',
].join("\n");

function measure(turn: TurnResult) {
    const firstText = turn.events.find((timed) => timed.event.ev === "text");
    let accumulated = "";
    let firstSpeakAtMs: number | undefined;
    for (const timed of turn.events) {
        if (timed.event.ev !== "text") continue;
        accumulated += timed.event.delta;
        const completeLines = accumulated.split("\n").slice(0, -1);
        if (completeLines.some((line) => /"type"\s*:\s*"speak"/.test(line))) {
            firstSpeakAtMs = timed.receivedAtMs;
            break;
        }
    }
    const usage = turn.events.filter((timed) => timed.event.ev === "usage").map((timed) => timed.event);
    return {
        ttftMs: firstText ? firstText.receivedAtMs - turn.sentAtMs : undefined,
        firstSpeakMs: firstSpeakAtMs ? firstSpeakAtMs - turn.sentAtMs : undefined,
        totalMs: (turn.events.at(-1)?.receivedAtMs ?? turn.sentAtMs) - turn.sentAtMs,
        outputTokens: usage.reduce((sum, event) => sum + (event.outputTokens ?? 0), 0),
    };
}

const engine = new EngineClient({ profile, responseTimeoutMs: 30_000 });
const lines: string[] = [
    `# S02 / S3 latency probe: ${new Date().toISOString().slice(0, 16).replace("T", " ")}`,
    "",
    `Profile \`${profile}\`, ${runs} measured runs per slot (+1 warm-up), screenshot 1568 px.`,
    "",
    "| Slot | Model | ok/runs | TTFT p50 | TTFT p95 | first speak p50 | first speak p95 | total p50 | out tokens p50 | Pass |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
];
let allPass = true;
for (const slot of slots) {
    const modelId = modelOverrides[slot] ?? resolveSlotModel(slot, { ...process.env, CHALK_MODEL_PROFILE: profile, GEMINI_API_KEY: "x", CHALK_STUB_BASE_URL: "x" }).modelId;
    await engine.start({ slot, model: modelId, prompt: PROMPT, images: [screenshot] });
    const measurements: ReturnType<typeof measure>[] = [];
    const errors: string[] = [];
    for (let run = 0; run < runs; run++) {
        if (delayMs > 0) await Bun.sleep(delayMs);
        const turn = await engine.start({ slot, model: modelId, prompt: PROMPT, images: [screenshot] });
        if (turn.error) errors.push(turn.error.kind);
        else measurements.push(measure(turn));
        process.stderr.write(`${slot} ${run + 1}/${runs}${turn.error ? ` error ${turn.error.kind}` : ""}\r`);
    }
    process.stderr.write("\n");
    const values = (key: "ttftMs" | "firstSpeakMs" | "totalMs" | "outputTokens") =>
        measurements.map((measurement) => measurement[key]).filter((value): value is number => value !== undefined);
    const ttftP50 = percentile(values("ttftMs"), 0.5);
    const firstSpeakP50 = percentile(values("firstSpeakMs"), 0.5);
    const threshold = THRESHOLDS[slot] ?? {};
    const pass =
        measurements.length > 0 &&
        (threshold.ttftP50 === undefined || (ttftP50 ?? Infinity) <= threshold.ttftP50) &&
        (threshold.firstSpeakP50 === undefined || (firstSpeakP50 ?? Infinity) <= threshold.firstSpeakP50);
    if (!pass) allPass = false;
    const formatMs = (value: number | undefined) => (value === undefined ? "–" : `${Math.round(value)} ms`);
    lines.push(
        `| ${slot} | \`${modelId}\` | ${measurements.length}/${runs}${errors.length ? ` (${[...new Set(errors)].join(", ")})` : ""} | ${formatMs(ttftP50)} | ${formatMs(percentile(values("ttftMs"), 0.95))} | ${formatMs(firstSpeakP50)} | ${formatMs(percentile(values("firstSpeakMs"), 0.95))} | ${formatMs(percentile(values("totalMs"), 0.5))} | ${percentile(values("outputTokens"), 0.5) ?? "–"} | ${pass ? "✅" : "❌"} |`,
    );
}
await engine.close();
lines.push("", "Thresholds (§15 S3): fast TTFT p50 ≤ 600 ms; teaching TTFT p50 ≤ 900 ms, first speak p50 ≤ 1100 ms. Grounding/deep: informational.");
const report = lines.join("\n");
console.log(report);
const resultsDirectory = join(REPO_ROOT, "Eval", "results");
mkdirSync(resultsDirectory, { recursive: true });
const reportPath = join(resultsDirectory, `S02-latency-${profile}-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "")}.md`);
writeFileSync(reportPath, `${report}\n`);
console.error(`report written to ${reportPath}`);
process.exit(allPass ? 0 : 1);
