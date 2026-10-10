// Shared by probe-vision.ts (S1, through the engine) and probe-cline-api.ts (S1b, Cline's
// OpenAI-compatible API): build a random probe image and score a model's reading of it.
import { existsSync, mkdirSync, mkdtempSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO_ROOT = join(import.meta.dir, "..", "..");
const BUILD_DIRECTORY = join(REPO_ROOT, "Eval", ".build");

const PROBE_WORDS = [
    "KESTREL", "MAPLE", "ORBIT", "QUARTZ", "LANTERN", "HARBOR", "VELVET", "PIXEL", "SUMMIT", "GLACIER",
    "TULIP", "COMET", "BRAMBLE", "CINDER", "FALCON", "MEADOW", "NECTAR", "OPAL", "PRISM", "RAVEN",
    "SAFFRON", "TIMBER", "UMBER", "VIOLET", "WILLOW", "ZEPHYR", "ANVIL", "BEACON", "CANYON", "DELTA",
];

export type ProbeImage = { path: string; words: [string, string, string]; number: string };
export type ProbeScore = { labelsCorrect: number; numberCorrect: boolean; verdict: "sees" | "blind" | "partial" | "unparsed" };

function ensureProbeGenerator(): string {
    const binary = join(BUILD_DIRECTORY, "make-probe");
    const source = join(REPO_ROOT, "Eval", "vision-probe", "make-probe.swift");
    if (!existsSync(binary) || statSync(binary).mtimeMs < statSync(source).mtimeMs) {
        mkdirSync(BUILD_DIRECTORY, { recursive: true });
        const compile = Bun.spawnSync(["swiftc", "-O", "-o", binary, source], { stderr: "pipe" });
        if (compile.exitCode !== 0) throw new Error(`swiftc failed:\n${compile.stderr}`);
    }
    return binary;
}

export function makeProbeImage(): ProbeImage {
    const shuffled = [...PROBE_WORDS].sort(() => Math.random() - 0.5);
    const words: [string, string, string] = [shuffled[0], shuffled[1], shuffled[2]];
    const number = String(1000 + Math.floor(Math.random() * 9000));
    const path = join(mkdtempSync(join(tmpdir(), "chalk-vision-probe-")), "probe.png");
    const run = Bun.spawnSync([ensureProbeGenerator(), path, ...words, number], { stderr: "pipe" });
    if (run.exitCode !== 0) throw new Error(`make-probe failed:\n${run.stderr}`);
    return { path, words, number };
}

export const PROBE_PROMPT = [
    "Look at this screenshot. Three magenta tags numbered 1, 2 and 3 each sit next to one word, and there is an order number.",
    'Reply with only a JSON object: {"1": "<word next to tag 1>", "2": "<word next to tag 2>", "3": "<word next to tag 3>", "number": "<the 4-digit order number>"}.',
    'If you cannot see an image, reply {"1": null, "2": null, "3": null, "number": null}.',
].join(" ");

export function scoreProbeAnswer(answerText: string, probe: ProbeImage): ProbeScore {
    const jsonMatch = answerText.match(/\{[\s\S]*\}/);
    if (!jsonMatch) return { labelsCorrect: 0, numberCorrect: false, verdict: "unparsed" };
    let answer: Record<string, unknown>;
    try {
        answer = JSON.parse(jsonMatch[0]);
    } catch {
        return { labelsCorrect: 0, numberCorrect: false, verdict: "unparsed" };
    }
    const normalize = (value: unknown) => String(value ?? "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
    const labelsCorrect = probe.words.filter((word, index) => normalize(answer[String(index + 1)]) === word).length;
    const numberCorrect = normalize(answer.number) === probe.number;
    const verdict = labelsCorrect === 3 && numberCorrect ? "sees" : labelsCorrect === 0 && !numberCorrect ? "blind" : "partial";
    return { labelsCorrect, numberCorrect, verdict };
}
