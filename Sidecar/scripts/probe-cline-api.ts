// Spike S1b (§15, §7.3 "Cline API … fallback adapter"): does Cline's OpenAI-compatible
// chat-completions endpoint accept images (`image_url` parts)? Image input there is undocumented.
// If it does, the emergency adapter can still answer screen questions; if not, it stays text-only.
//
// Usage: CLINE_API_KEY=... bun Sidecar/scripts/probe-cline-api.ts [--model anthropic/claude-sonnet-5.5]
// Exit 0 = images accepted and read correctly, 1 = not, 3 = skipped (no CLINE_API_KEY).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { option, pngDataUrl } from "./engine-client";
import { makeProbeImage, PROBE_PROMPT, scoreProbeAnswer } from "./vision-probe-common";

const CLINE_CHAT_COMPLETIONS_URL = "https://api.cline.bot/api/v1/chat/completions";
const model = option("model", "anthropic/claude-sonnet-5.5");
const apiKey = process.env.CLINE_API_KEY;
if (!apiKey) {
    console.error("SKIPPED: set CLINE_API_KEY (a Cline API key) to run S1b.");
    process.exit(3);
}

const probe = makeProbeImage();
const startedAt = performance.now();
const response = await fetch(CLINE_CHAT_COMPLETIONS_URL, {
    method: "POST",
    headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
        model,
        stream: false,
        max_tokens: 200,
        messages: [
            {
                role: "user",
                content: [
                    { type: "text", text: PROBE_PROMPT },
                    { type: "image_url", image_url: { url: pngDataUrl(probe.path) } },
                ],
            },
        ],
    }),
});
const latencyMs = Math.round(performance.now() - startedAt);
const bodyText = await response.text();
let answerText = "";
try {
    // Cline wraps the OpenAI-style body in {"data": …} (seen 2026-10-03); accept both shapes.
    const body = JSON.parse(bodyText);
    answerText = (body?.data ?? body)?.choices?.[0]?.message?.content ?? "";
} catch {}
const score = response.ok ? scoreProbeAnswer(answerText, probe) : undefined;
const pass = score?.verdict === "sees";

const report = [
    `# S02 / S1b Cline API image probe: ${new Date().toISOString().slice(0, 16).replace("T", " ")}`,
    "",
    `\`POST ${CLINE_CHAT_COMPLETIONS_URL}\` with an \`image_url\` part, model \`${model}\`.`,
    "",
    `- HTTP ${response.status} in ${latencyMs} ms`,
    `- Expected: ${probe.words.join(" ")} #${probe.number}`,
    `- Answer: ${(answerText || bodyText).replace(/\s+/g, " ").slice(0, 200)}`,
    `- Verdict: ${score ? `${score.verdict} (labels ${score.labelsCorrect}/3, number ${score.numberCorrect ? "✓" : "✗"})` : "request failed"}`,
    "",
    pass ? "**Pass:** the fallback adapter can send screenshots." : "**Fail:** keep the fallback adapter text-only (§15 S1b plan B).",
].join("\n");
console.log(report);
const resultsDirectory = join(import.meta.dir, "..", "..", "Eval", "results");
mkdirSync(resultsDirectory, { recursive: true });
writeFileSync(join(resultsDirectory, `S02-cline-api-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "")}.md`), `${report}\n`);
process.exit(pass ? 0 : 1);
