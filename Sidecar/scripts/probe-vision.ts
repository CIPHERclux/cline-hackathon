// Spike S1 (§15, §7.4 capability guard): does a screenshot really reach each candidate model
// through Cline? Each model reads a fresh random probe image (3 tagged words + a 4-digit number)
// through tutor-engine. A text-only control model must come out "blind": the SDK silently swaps
// images for "[Image attached — this model cannot view images]", and we must be able to tell.
//
// Usage (repo root or Sidecar/):
//   bun Sidecar/scripts/probe-vision.ts [--profile demo] [--models a,b] [--control openai/gpt-oss-20b|none]
//                                       [--delay-ms 0] [--retries 1] [--response-timeout-ms 30000]
// Default models: every primary and fallback in the profile. Exit 1 if any candidate can't read
// all 3 labels and the number, or the control isn't detected as blind.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import modelRouting from "../model-routing.json";
import { EngineClient, option, pngDataUrl } from "./engine-client";
import { makeProbeImage, PROBE_PROMPT, scoreProbeAnswer } from "./vision-probe-common";

const profile = option("profile", "demo");
const profileConfig = (modelRouting.profiles as Record<string, any>)[profile];
if (!profileConfig) throw new Error(`unknown profile ${profile}`);
const candidateModels = option("models", "")
    .split(",")
    .filter(Boolean);
if (candidateModels.length === 0) {
    for (const slot of Object.values(profileConfig.slots) as { primary: string; fallbacks: string[] }[]) {
        for (const modelId of [slot.primary, ...slot.fallbacks]) if (!candidateModels.includes(modelId)) candidateModels.push(modelId);
    }
}
const controlModel = option("control", profile === "demo" ? "openai/gpt-oss-20b" : "none");
const delayMs = Number(option("delay-ms", "0"));
// A busy provider ("high demand", 5xx) says nothing about vision; try again before judging.
const retries = Number(option("retries", "1"));
const engine = new EngineClient({ profile, responseTimeoutMs: Number(option("response-timeout-ms", "30000")) });

type Row = { model: string; role: "candidate" | "control"; verdict: string; detail: string; latencyMs?: number; pass: boolean };
const rows: Row[] = [];
const models: [string, "candidate" | "control"][] = [
    ...candidateModels.map((model) => [model, "candidate"] as [string, "candidate"]),
    ...(controlModel === "none" ? [] : [[controlModel, "control"] as [string, "control"]]),
];
for (const [index, [model, role]] of models.entries()) {
    if (index > 0 && delayMs > 0) await Bun.sleep(delayMs);
    const probe = makeProbeImage();
    let turn = await engine.start({ slot: "grounding", model, prompt: PROBE_PROMPT, images: [pngDataUrl(probe.path)] });
    for (let attempt = 0; attempt < retries && turn.error?.retryable; attempt++) {
        console.error(`${model}: ${turn.error.kind} (retryable), retrying`);
        await Bun.sleep(Math.max(delayMs, 3000));
        turn = await engine.start({ slot: "grounding", model, prompt: PROBE_PROMPT, images: [pngDataUrl(probe.path)] });
    }
    const latencyMs = Math.round((turn.events.at(-1)?.receivedAtMs ?? turn.sentAtMs) - turn.sentAtMs);
    if (turn.error) {
        rows.push({ model, role, verdict: "error", detail: `${turn.error.kind}: ${turn.error.message.slice(0, 80)}`, latencyMs, pass: false });
        console.error(`${model}: error ${turn.error.kind}`);
        continue;
    }
    const score = scoreProbeAnswer(turn.text, probe);
    // A text-only model may answer in prose ("I can't see an image"): that is blind too.
    const pass = role === "candidate" ? score.verdict === "sees" : score.verdict === "blind" || score.verdict === "unparsed";
    rows.push({
        model,
        role,
        verdict: score.verdict,
        detail: `labels ${score.labelsCorrect}/3, number ${score.numberCorrect ? "✓" : "✗"} (expected ${probe.words.join(" ")} #${probe.number}; got ${turn.text.replace(/\s+/g, " ").slice(0, 90)})`,
        latencyMs,
        pass,
    });
    console.error(`${model}: ${score.verdict}`);
}
await engine.close();

const lines = [
    `# S02 / S1 vision probe: ${new Date().toISOString().slice(0, 16).replace("T", " ")}`,
    "",
    `Profile \`${profile}\`. Pass: candidates read 3/3 labels and the number; the text-only control is detected as blind.`,
    "",
    "| Model | Role | Verdict | Pass | ms | Detail |",
    "|---|---|---|---|---|---|",
    ...rows.map((row) => `| \`${row.model}\` | ${row.role} | ${row.verdict} | ${row.pass ? "✅" : "❌"} | ${row.latencyMs ?? ""} | ${row.detail.replace(/\|/g, "/")} |`),
    "",
    `**${rows.filter((row) => row.pass).length}/${rows.length} pass.** Failing candidates must leave the image slots (§7.4 capability guard).`,
];
const report = lines.join("\n");
console.log(report);
const resultsDirectory = join(import.meta.dir, "..", "..", "Eval", "results");
mkdirSync(resultsDirectory, { recursive: true });
const reportPath = join(resultsDirectory, `S02-vision-${profile}-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "")}.md`);
writeFileSync(reportPath, `${report}\n`);
console.error(`report written to ${reportPath}`);
process.exit(rows.every((row) => row.pass) ? 0 : 1);
