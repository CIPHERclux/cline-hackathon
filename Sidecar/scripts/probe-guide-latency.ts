// Planner latency: a ClineCore session turn (start, then send on the same session) against the
// fast path (`complete`, no agent loop or rules), same prompt and screenshot. Free dev profile by
// default; `--profile demo` spends Cline credits and needs the owner's OK.
// Usage: bun scripts/probe-guide-latency.ts [--profile dev] [--runs 3] [--image path]
import { EngineClient, option, percentile, pngDataUrl, type TurnResult } from "./engine-client";

const profile = option("profile", "dev");
const runs = Number(option("runs", "3"));
const image = pngDataUrl(option("image", `${import.meta.dir}/../../Eval/pointing/fixtures/real-01.png`));

const system =
    "You are Chalk's planner. You guide a user through a task on their Mac one action at a time. " +
    'Reply with exactly one JSON line: {"status":"step","step":{"kind":"click","instruction":"…","target":{"role":"button","name":"…"},"done":{"exists":"…"}}}';
const controls = Array.from({ length: 60 }, (_, index) => `button, Control ${index + 1}`).join("\n");
const prompt = `Goal: find the cheapest flight from London to Paris next Friday.\nDone so far: opened Google Flights.\nFrontmost app: Google Chrome\nControls on screen:\n${controls}\nWhat is the next single action?`;

function timings(result: TurnResult) {
    const first = result.events.find((timed) => timed.event.ev === "text");
    const last = result.events.at(-1);
    return {
        firstTextMs: first ? Math.round(first.receivedAtMs - result.sentAtMs) : undefined,
        totalMs: last ? Math.round(last.receivedAtMs - result.sentAtMs) : undefined,
        error: result.error?.message,
    };
}

const client = new EngineClient({ profile });
const rows: Record<string, { first: number[]; total: number[] }> = {};
function record(mode: string, result: TurnResult) {
    const timing = timings(result);
    console.log(mode, JSON.stringify(timing), JSON.stringify(result.text.slice(0, 120)));
    rows[mode] ??= { first: [], total: [] };
    if (timing.firstTextMs !== undefined) rows[mode].first.push(timing.firstTextMs);
    if (timing.totalMs !== undefined && !timing.error) rows[mode].total.push(timing.totalMs);
}

for (let run = 0; run < runs; run++) {
    const started = await client.request({ op: "start", slot: "teaching", prompt: `${system}\n\n${prompt}`, images: [image] });
    record("session-start", started);
    const sessionId = started.events.find((timed) => timed.event.ev === "session")?.event.sessionId;
    if (sessionId) {
        record("session-send", await client.request({ op: "send", sessionId, prompt, images: [image] }));
        await client.request({ op: "abort", sessionId });
    }
    record("complete", await client.request({ op: "complete", slot: "teaching", system, prompt, images: [image], maxTokens: 300 }));
}
await client.close();
console.log("\nmode           first-text p50   total p50");
for (const [mode, values] of Object.entries(rows)) {
    console.log(`${mode.padEnd(15)}${String(percentile(values.first, 0.5) ?? "-").padStart(10)} ms${String(percentile(values.total, 0.5) ?? "-").padStart(10)} ms`);
}
