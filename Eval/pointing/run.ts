// Pointing check (D40): can the model point at things on real screens, through our own engine?
// For each target it asks the model twice, through tutor-engine (same ClineCore path as the app):
//   som: "which numbered mark is it?" on the set-of-marks image (§6.2 c), resolved to the mark
//   raw: "give x,y (0–1000)" on the clean image, as a baseline
// and scores a hit when the resolved point falls inside the ground-truth box (§6.8 hit rate).
// Answers are cached under Eval/pointing/.cache, so re-running or re-scoring costs no requests.
//
// Usage (from the repo root):
//   bun Eval/pointing/run.ts [--profile dev] [--slot grounding] [--modes som,raw]
//                            [--max-requests 30] [--delay-ms 4500] [--only id1,id2]
//                            [--response-timeout-ms 60000] [--model <id>]
// Needs Sidecar/dist/tutor-engine (cd Sidecar && bun run build:bin). On the dev profile the
// Gemini key comes from env GEMINI_API_KEY or the Keychain item chalk.dev.gemini-api-key.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { EngineClient, option, pngDataUrl } from "../../Sidecar/scripts/engine-client";
import { resolveSlotModel } from "../../Sidecar/src/routing";

type Box = [number, number, number, number];
type Mark = { id: number; kind: string; text?: string; box: Box };
// marks: capped, shown to the model in set-of-marks mode. snapMarks: uncapped, what a raw point
// snaps to (D48); older files without it fall back to marks.
type MarksFile = { imageWidth: number; imageHeight: number; modelWidth: number; modelHeight: number; modelScale: number; marks: Mark[]; snapMarks?: Mark[] };
type Target = { id: string; image: string; question: string; expect: { box?: Box; text?: string } };
type TargetsFile = { images: Record<string, { path: string; scale: number }>; targets: Target[] };
type ModelAnswer = { text: string; error?: string; latencyMs: number; model: string };
// som: pick a mark; raw: x,y only; hybrid: pick a mark, or x,y when no mark covers the target
// (§6.2 target resolution: mark first, raw px as the low-confidence last resort);
// snap: the raw answer (no extra request) snapped to the smallest mark containing it, which
// gives the renderer an exact outline to draw around;
// zoom: the raw answer, then a second ask on a native-resolution crop around it (§6.2 d), snapped.
type Mode = "som" | "raw" | "hybrid" | "snap" | "zoom";

const POINTING_DIRECTORY = import.meta.dir;
const REPO_ROOT = join(POINTING_DIRECTORY, "..", "..");
const BUILD_DIRECTORY = join(REPO_ROOT, "Eval", ".build");
const CACHE_DIRECTORY = join(POINTING_DIRECTORY, ".cache");
const profile = option("profile", "dev");
const slot = option("slot", "grounding") as "fast" | "teaching" | "grounding" | "deep";
const modes = option("modes", "som,raw").split(",") as Mode[];
const maximumRequests = Number(option("max-requests", "30"));
const delayBetweenRequestsMs = Number(option("delay-ms", "4500"));
const onlyTargetIds = option("only", "").split(",").filter(Boolean);
// A specific model within the profile's provider instead of the slot's primary (D41).
const modelOverride = option("model", "") || undefined;
const targetsPath = option("targets", join(POINTING_DIRECTORY, "targets.json"));
// Accuracy, not latency, is measured here, so a busy free tier gets longer than the live 15 s.
const responseTimeoutMs = Number(option("response-timeout-ms", "60000"));

// ---- candidates (Swift CLI, §6.2 b + c) -------------------------------------------------------

// The app's own perception code (ChalkCore's VisionCandidateDetector + MarkSelection), built as
// the `grounding-marks` tool, so the harness measures exactly what the app does (S05).
function ensureMarksBinary(): string {
    const packagePath = join(REPO_ROOT, "Packages", "ChalkCore");
    const build = Bun.spawnSync(["swift", "build", "--package-path", packagePath, "-c", "release", "--product", "grounding-marks"], {
        stdout: "ignore",
        stderr: "pipe",
    });
    if (build.exitCode !== 0) throw new Error(`swift build failed:\n${build.stderr}`);
    return join(packagePath, ".build", "release", "grounding-marks");
}

// The zoom pass crops a third of the screen in each direction around the first guess, at native
// resolution: on a 3024 px Retina screenshot that is ~1.9× the detail of the 1568 px full image.
const ZOOM_FRACTION = 1 / 3;

function ensureCropBinary(): string {
    const binary = join(BUILD_DIRECTORY, "crop");
    const source = join(POINTING_DIRECTORY, "crop.swift");
    if (!existsSync(binary) || statSync(binary).mtimeMs < statSync(source).mtimeMs) {
        const compile = Bun.spawnSync(["swiftc", "-O", "-o", binary, source], { stderr: "pipe" });
        if (compile.exitCode !== 0) throw new Error(`swiftc failed:\n${compile.stderr}`);
    }
    return binary;
}

function zoomCrop(imagePath: string, marksFile: MarksFile, x: number, y: number) {
    const width = Math.round(marksFile.imageWidth * ZOOM_FRACTION);
    const height = Math.round(marksFile.imageHeight * ZOOM_FRACTION);
    const left = Math.round(Math.min(Math.max(x - width / 2, 0), marksFile.imageWidth - width));
    const top = Math.round(Math.min(Math.max(y - height / 2, 0), marksFile.imageHeight - height));
    const cropPath = join(BUILD_DIRECTORY, "marks-out", `${imagePath.split("/").at(-1)!.replace(/\.[^.]+$/, "")}.zoom-${left}-${top}.png`);
    const run = Bun.spawnSync([ensureCropBinary(), imagePath, cropPath, String(left), String(top), String(width), String(height)], { stderr: "pipe" });
    if (run.exitCode !== 0) throw new Error(`crop failed: ${run.stderr}`);
    return { cropPath, left, top, width, height };
}

function marksFor(imageName: string, imagePath: string): { marks: MarksFile; somPng: string; modelPng: string } {
    const outputDirectory = join(BUILD_DIRECTORY, "marks-out");
    const run = Bun.spawnSync([ensureMarksBinary(), imagePath, outputDirectory], { stderr: "pipe" });
    if (run.exitCode !== 0) throw new Error(`marks failed for ${imagePath}:\n${run.stderr}`);
    process.stderr.write(run.stderr.toString());
    const baseName = imagePath.split("/").at(-1)!.replace(/\.[^.]+$/, "");
    return {
        marks: JSON.parse(readFileSync(join(outputDirectory, `${baseName}.marks.json`), "utf8")),
        somPng: join(outputDirectory, `${baseName}.som.png`),
        modelPng: join(outputDirectory, `${baseName}.model.png`),
    };
}

// ---- prompts --------------------------------------------------------------------------------

function marksList(marksFile: MarksFile): string {
    return marksFile.marks
        .map((mark) => {
            const centerX = Math.round((mark.box[0] + mark.box[2] / 2) * marksFile.modelScale);
            const centerY = Math.round((mark.box[1] + mark.box[3] / 2) * marksFile.modelScale);
            const label = mark.text ? ` "${mark.text.replace(/"/g, "'")}"` : "";
            return `m${mark.id} ${mark.kind}${label} (${centerX},${centerY})`;
        })
        .join("\n");
}

function setOfMarksPrompt(marksFile: MarksFile, question: string): string {
    return [
        `You are locating one element on a screenshot of a Mac app (${marksFile.modelWidth}×${marksFile.modelHeight} pixels).`,
        "Numbered magenta tags mark candidate elements. Each line below is: mark id, kind, any text it contains, and its centre in image pixels.",
        "",
        marksList(marksFile),
        "",
        `Target: ${question}`,
        "",
        'Answer with only a JSON object: {"mark": <id>} for the mark that best covers the target, or {"mark": null} if no mark covers it. No other text.',
    ].join("\n");
}

function hybridPrompt(marksFile: MarksFile, question: string): string {
    return [
        `You are locating one element on a screenshot of a Mac app (${marksFile.modelWidth}×${marksFile.modelHeight} pixels).`,
        "Numbered magenta tags mark candidate elements. Each line below is: mark id, kind, any text it contains, and its centre in image pixels.",
        "",
        marksList(marksFile),
        "",
        `Target: ${question}`,
        "",
        'If a mark covers the target, answer with only {"mark": <id>}.',
        'If no mark covers it, answer with only {"x": <0-1000>, "y": <0-1000>}: the centre of the target, normalized to 0–1000 (0,0 = top-left corner, 1000,1000 = bottom-right corner).',
        "No other text.",
    ].join("\n");
}

function rawCoordinatePrompt(question: string): string {
    return [
        "You are locating one element on a screenshot of a Mac app.",
        `Target: ${question}`,
        "",
        'Answer with only a JSON object {"x": <0-1000>, "y": <0-1000>}: the centre of the target, in coordinates normalized to 0–1000 (0,0 = top-left corner, 1000,1000 = bottom-right corner). No other text.',
    ].join("\n");
}

// ---- scoring --------------------------------------------------------------------------------

const center = (box: Box) => [box[0] + box[2] / 2, box[1] + box[3] / 2] as const;
const contains = (box: Box, x: number, y: number) => x >= box[0] && x <= box[0] + box[2] && y >= box[1] && y <= box[1] + box[3];

function intersectionOverUnion(first: Box, second: Box): number {
    const overlapWidth = Math.min(first[0] + first[2], second[0] + second[2]) - Math.max(first[0], second[0]);
    const overlapHeight = Math.min(first[1] + first[3], second[1] + second[3]) - Math.max(first[1], second[1]);
    if (overlapWidth <= 0 || overlapHeight <= 0) return 0;
    const overlap = overlapWidth * overlapHeight;
    return overlap / (first[2] * first[3] + second[2] * second[3] - overlap);
}

function groundTruthBox(target: Target, marksFile: MarksFile): Box | undefined {
    if (target.expect.box) return target.expect.box;
    const wanted = target.expect.text?.toLowerCase();
    const textMarks = marksFile.marks.filter((mark) => mark.kind === "text" && mark.text);
    return (textMarks.find((mark) => mark.text!.toLowerCase() === wanted) ?? textMarks.find((mark) => mark.text!.toLowerCase().includes(wanted ?? "\u0000")))?.box;
}

function resolvePoint(mode: Mode, answerText: string, marksFile: MarksFile): { x: number; y: number; note: string } | undefined {
    if (mode === "som" || mode === "hybrid") {
        const match = answerText.match(/"mark"\s*:\s*(null|"?m?(\d+)"?)/);
        const mark = match && match[1] !== "null" ? marksFile.marks.find((candidate) => candidate.id === Number(match[2])) : undefined;
        if (mark) {
            const [x, y] = center(mark.box);
            return { x, y, note: `m${mark.id}${mark.text ? ` "${mark.text}"` : ` ${mark.kind}`}` };
        }
        if (mode === "som") return undefined;
    }
    const xMatch = answerText.match(/"x"\s*:\s*(-?[\d.]+)/);
    const yMatch = answerText.match(/"y"\s*:\s*(-?[\d.]+)/);
    if (!xMatch || !yMatch) return undefined;
    const x = (Number(xMatch[1]) / 1000) * marksFile.imageWidth;
    const y = (Number(yMatch[1]) / 1000) * marksFile.imageHeight;
    if (mode === "snap") {
        // Smallest control-sized mark (≤ 400 px a side) under the point.
        const containing = (marksFile.snapMarks ?? marksFile.marks)
            .filter((mark) => contains(mark.box, x, y) && mark.box[2] <= 400 && mark.box[3] <= 400)
            .sort((first, second) => first.box[2] * first.box[3] - second.box[2] * second.box[3])[0];
        if (containing) {
            const [snappedX, snappedY] = center(containing.box);
            return { x: snappedX, y: snappedY, note: `m${containing.id}${containing.text ? ` "${containing.text}"` : ` ${containing.kind}`}` };
        }
    }
    return { x, y, note: `(${Math.round(x)},${Math.round(y)})px` };
}

// ---- main -----------------------------------------------------------------------------------

const targetsFile: TargetsFile = JSON.parse(readFileSync(targetsPath, "utf8"));
const targets = targetsFile.targets.filter((target) => onlyTargetIds.length === 0 || onlyTargetIds.includes(target.id));
const modelId = resolveSlotModel(slot, { CHALK_MODEL_PROFILE: profile, GEMINI_API_KEY: "x", CHALK_STUB_BASE_URL: "x" }, modelOverride).modelId;
mkdirSync(CACHE_DIRECTORY, { recursive: true });

const perception = new Map<string, ReturnType<typeof marksFor>>();
for (const imageName of new Set(targets.map((target) => target.image))) {
    const image = targetsFile.images[imageName];
    perception.set(imageName, marksFor(imageName, join(dirname(targetsPath), image.path)));
}

let engine: EngineClient | undefined;
let requestsMade = 0;
let stoppedReason: string | undefined;

// For zoom, the crop geometry of the last answer, to map crop coordinates back to the screen.
const zoomGeometryByTarget = new Map<string, { left: number; top: number; width: number; height: number }>();

async function answer(mode: Mode, target: Target): Promise<ModelAnswer | undefined> {
    if (mode === "snap") return answer("raw", target);
    const { marks, somPng, modelPng } = perception.get(target.image)!;
    let prompt =
        mode === "som" ? setOfMarksPrompt(marks, target.question) : mode === "hybrid" ? hybridPrompt(marks, target.question) : rawCoordinatePrompt(target.question);
    let imagePng = mode === "raw" ? modelPng : somPng;
    if (mode === "zoom") {
        const firstGuess = await answer("raw", target);
        const firstPoint = firstGuess && !firstGuess.error ? resolvePoint("raw", firstGuess.text, marks) : undefined;
        if (!firstPoint) return firstGuess;
        const imagePath = join(dirname(targetsPath), targetsFile.images[target.image].path);
        const crop = zoomCrop(imagePath, marks, firstPoint.x, firstPoint.y);
        zoomGeometryByTarget.set(target.id, crop);
        imagePng = crop.cropPath;
        prompt = [
            "This is a zoomed-in crop of a screenshot of a Mac app.",
            `Target: ${target.question}`,
            "",
            'Answer with only a JSON object {"x": <0-1000>, "y": <0-1000>}: the centre of the target within this crop, normalized to 0–1000 (0,0 = top-left corner of the crop, 1000,1000 = bottom-right). No other text.',
        ].join("\n");
    }
    const imageHash = createHash("sha256").update(readFileSync(imagePng)).digest("hex");
    const cacheKey = createHash("sha256").update(JSON.stringify({ profile, modelId, mode, prompt, imageHash })).digest("hex").slice(0, 32);
    const cacheFile = join(CACHE_DIRECTORY, `${cacheKey}.json`);
    if (existsSync(cacheFile)) return JSON.parse(readFileSync(cacheFile, "utf8"));
    if (stoppedReason) return undefined;
    if (requestsMade >= maximumRequests) {
        stoppedReason = `request cap (${maximumRequests}) reached`;
        return undefined;
    }

    if (!engine) engine = new EngineClient({ profile, responseTimeoutMs });
    else if (delayBetweenRequestsMs > 0) await Bun.sleep(delayBetweenRequestsMs);
    requestsMade += 1;
    const turn = await engine.start({ slot, model: modelId, prompt, images: [pngDataUrl(imagePng)] });
    const result: ModelAnswer = {
        text: turn.text,
        error: turn.error ? `${turn.error.kind}: ${turn.error.message}` : undefined,
        latencyMs: Math.round((turn.events.at(-1)?.receivedAtMs ?? turn.sentAtMs) - turn.sentAtMs),
        model: turn.model ?? modelId,
    };
    if (turn.error?.kind === "rate_limit" || turn.error?.kind === "auth") {
        stoppedReason = `${turn.error.kind}: ${turn.error.message}`;
        return result;
    }
    if (!turn.error) writeFileSync(cacheFile, JSON.stringify(result, null, 2));
    return result;
}

type Row = { target: Target; recall: boolean; snapRecall: boolean; results: Record<string, { hit?: boolean; note: string; errorPt?: number; latencyMs?: number }> };
const rows: Row[] = [];
for (const target of targets) {
    const { marks } = perception.get(target.image)!;
    const truth = groundTruthBox(target, marks);
    const pointsPerPixel = 1 / (targetsFile.images[target.image].scale || 1);
    const row: Row = {
        target,
        recall: truth ? marks.marks.some((mark) => intersectionOverUnion(mark.box, truth) >= 0.5 || contains(truth, ...center(mark.box))) : false,
        snapRecall: truth
            ? (marks.snapMarks ?? marks.marks).some((mark) => intersectionOverUnion(mark.box, truth) >= 0.5 || contains(truth, ...center(mark.box)))
            : false,
        results: {},
    };
    for (const mode of modes) {
        if (!truth) {
            row.results[mode] = { note: "no ground truth" };
            continue;
        }
        const modelAnswer = await answer(mode, target);
        if (!modelAnswer) {
            row.results[mode] = { note: "skipped" };
            continue;
        }
        if (modelAnswer.error) {
            row.results[mode] = { note: modelAnswer.error.slice(0, 60), latencyMs: modelAnswer.latencyMs };
            continue;
        }
        let point = resolvePoint(mode === "zoom" ? "snap" : mode, modelAnswer.text, marks);
        if (mode === "zoom") {
            const crop = zoomGeometryByTarget.get(target.id);
            const xMatch = modelAnswer.text.match(/"x"\s*:\s*(-?[\d.]+)/);
            const yMatch = modelAnswer.text.match(/"y"\s*:\s*(-?[\d.]+)/);
            if (crop && xMatch && yMatch) {
                // Crop coordinates → screen, then snap like `snap` (as if the model had answered there).
                const screenX = crop.left + (Number(xMatch[1]) / 1000) * crop.width;
                const screenY = crop.top + (Number(yMatch[1]) / 1000) * crop.height;
                const normalized = `{"x": ${(screenX / marks.imageWidth) * 1000}, "y": ${(screenY / marks.imageHeight) * 1000}}`;
                point = resolvePoint("snap", normalized, marks);
            } else point = undefined;
        }
        if (!point) {
            row.results[mode] = { hit: false, note: `unparsed: ${modelAnswer.text.slice(0, 40).replace(/\s+/g, " ")}`, latencyMs: modelAnswer.latencyMs };
            continue;
        }
        const [truthX, truthY] = center(truth);
        row.results[mode] = {
            hit: contains(truth, point.x, point.y),
            note: point.note,
            errorPt: Math.hypot(point.x - truthX, point.y - truthY) * pointsPerPixel,
            latencyMs: modelAnswer.latencyMs,
        };
    }
    rows.push(row);
}
await engine?.close();

// ---- report ---------------------------------------------------------------------------------

const lines: string[] = [];
lines.push(`# Pointing check: ${new Date().toISOString().slice(0, 16).replace("T", " ")}`);
lines.push("");
lines.push(`Profile \`${profile}\`, slot \`${slot}\` → \`${modelId}\`. New requests this run: ${requestsMade}${stoppedReason ? ` (stopped: ${stoppedReason})` : ""}.`);
lines.push("");
lines.push(`| Target | Question | Marks recall | ${modes.map((mode) => `${mode} hit | ${mode} answer | ${mode} err pt | ${mode} ms`).join(" | ")} |`);
lines.push(`|---|---|---|${modes.map(() => "---|---|---|---").join("|")}|`);
for (const row of rows) {
    const cells = modes.map((mode) => {
        const result = row.results[mode] ?? { note: "" };
        const hit = result.hit === undefined ? "–" : result.hit ? "✅" : "❌";
        return `${hit} | ${result.note.replace(/\|/g, "/")} | ${result.errorPt === undefined ? "" : result.errorPt.toFixed(0)} | ${result.latencyMs ?? ""}`;
    });
    lines.push(`| ${row.target.id} | ${row.target.question} | ${row.recall ? "yes" : "no"} | ${cells.join(" | ")} |`);
}
lines.push("");
const summaries: string[] = [];
const groups: [string, (row: Row) => boolean][] = [
    ["all", () => true],
    ["real screens", (row) => !row.target.image.startsWith("synthetic")],
];
for (const [groupName, inGroup] of groups) for (const mode of modes) {
    const scored = rows.filter(inGroup).map((row) => row.results[mode]).filter((result) => result?.hit !== undefined);
    const hits = scored.filter((result) => result.hit).length;
    const latencies = scored.map((result) => result.latencyMs!).filter(Boolean).sort((first, second) => first - second);
    const median = latencies.length ? latencies[Math.floor(latencies.length / 2)] : undefined;
    summaries.push(`**${mode}** (${groupName}): ${hits}/${scored.length} hit${scored.length ? ` (${Math.round((hits / scored.length) * 100)}%)` : ""}${median ? `, median ${median} ms` : ""}`);
}
const recallCount = rows.filter((row) => row.recall).length;
summaries.push(`**marks recall** (capped, set-of-marks): ${recallCount}/${rows.length} targets have a mark on them`);
const snapRecallCount = rows.filter((row) => row.snapRecall).length;
summaries.push(`**candidate recall** (uncapped snap targets, §6.8 gate ≥ 92%): ${snapRecallCount}/${rows.length} (${Math.round((snapRecallCount / Math.max(rows.length, 1)) * 100)}%)`);
lines.push(summaries.join(" · "));
lines.push("");
lines.push("Demo gate (§6.8): ≥ 85% hit. A mark-based miss with recall \"no\" needs better candidates or the zoom pass (§6.2 d), not a better model.");

const report = lines.join("\n");
console.log(report);
const resultsDirectory = join(REPO_ROOT, "Eval", "results");
mkdirSync(resultsDirectory, { recursive: true });
const reportPath = join(resultsDirectory, `pointing-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, "")}.md`);
writeFileSync(reportPath, `${report}\n`);
console.error(`report written to ${reportPath}`);
