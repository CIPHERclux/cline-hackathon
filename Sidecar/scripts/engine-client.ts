// Drives the compiled tutor-engine over its NDJSON protocol (§7.3) for the S02 probes and the
// pointing check, exactly as the Swift app will. Every event carries its arrival time so the
// latency probe can measure time-to-first-text and time-to-first-speak-line (§15 S3).
import { existsSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const ENGINE_BINARY = join(import.meta.dir, "..", "dist", "tutor-engine");

export type TimedEvent = { event: any; receivedAtMs: number };
export type TurnResult = {
    sentAtMs: number;
    events: TimedEvent[];
    model: string | undefined;
    text: string;
    error: { kind: string; message: string; retryable: boolean } | undefined;
};

export type EngineClientOptions = {
    profile: string;
    responseTimeoutMs?: number;
    extraEnvironment?: Record<string, string>;
};

// The dev profile's key lives in the owner's Keychain (D37); never in a file.
export function devGeminiKey(): string | undefined {
    if (process.env.GEMINI_API_KEY) return process.env.GEMINI_API_KEY;
    const lookup = Bun.spawnSync(["security", "find-generic-password", "-s", "chalk.dev.gemini-api-key", "-w"], { stderr: "pipe" });
    return lookup.exitCode === 0 ? lookup.stdout.toString().trim() : undefined;
}

export function pngDataUrl(path: string): string {
    return `data:image/png;base64,${readFileSync(path).toString("base64")}`;
}

export class EngineClient {
    private readonly child;
    private readonly waiters = new Map<string, () => void>();
    private readonly eventsByRequest = new Map<string, TimedEvent[]>();
    private requestCounter = 0;

    constructor(options: EngineClientOptions) {
        if (!existsSync(ENGINE_BINARY)) throw new Error(`no engine at ${ENGINE_BINARY}; run: cd Sidecar && bun run build:bin`);
        // Fresh CLINE_DIR per run, except on the demo profile, which needs the Cline sign-in (D10).
        const clineDirectory =
            options.profile === "demo"
                ? (process.env.CLINE_DIR ?? join(process.env.HOME ?? tmpdir(), "Library", "Application Support", "Chalk", "cline"))
                : mkdtempSync(join(tmpdir(), "chalk-probe-"));
        const geminiKey = options.profile === "dev" ? devGeminiKey() : undefined;
        this.child = Bun.spawn([ENGINE_BINARY], {
            env: {
                PATH: "/usr/bin:/bin",
                HOME: process.env.HOME ?? tmpdir(),
                CLINE_DIR: clineDirectory,
                CHALK_MODEL_PROFILE: options.profile,
                ...(options.responseTimeoutMs ? { CHALK_PROVIDER_RESPONSE_TIMEOUT_MS: String(options.responseTimeoutMs) } : {}),
                ...(geminiKey ? { GEMINI_API_KEY: geminiKey } : {}),
                ...options.extraEnvironment,
            },
            stdin: "pipe",
            stdout: "pipe",
            stderr: "ignore",
        });
        void this.readEvents();
    }

    async start(request: { slot: string; model?: string; prompt: string; images?: string[] }): Promise<TurnResult> {
        const requestId = `q${++this.requestCounter}`;
        const finished = new Promise<void>((resolve) => this.waiters.set(requestId, resolve));
        const sentAtMs = performance.now();
        this.child.stdin.write(`${JSON.stringify({ id: requestId, op: "start", ...request })}\n`);
        this.child.stdin.flush();
        await finished;
        const events = this.eventsByRequest.get(requestId) ?? [];
        const errorEvent = events.find((timed) => timed.event.ev === "error")?.event;
        return {
            sentAtMs,
            events,
            model: events.find((timed) => timed.event.ev === "session")?.event.model,
            text: events.filter((timed) => timed.event.ev === "text").map((timed) => timed.event.delta).join(""),
            error: errorEvent ? { kind: errorEvent.kind, message: errorEvent.message, retryable: errorEvent.retryable } : undefined,
        };
    }

    // Any op (start, send, complete): the request object minus its id.
    async request(payload: Record<string, unknown>): Promise<TurnResult> {
        const requestId = `q${++this.requestCounter}`;
        const finished = new Promise<void>((resolve) => this.waiters.set(requestId, resolve));
        const sentAtMs = performance.now();
        this.child.stdin.write(`${JSON.stringify({ id: requestId, ...payload })}\n`);
        this.child.stdin.flush();
        await finished;
        const events = this.eventsByRequest.get(requestId) ?? [];
        const errorEvent = events.find((timed) => timed.event.ev === "error")?.event;
        return {
            sentAtMs,
            events,
            model: events.find((timed) => timed.event.ev === "session")?.event.model,
            text: events.filter((timed) => timed.event.ev === "text").map((timed) => timed.event.delta).join(""),
            error: errorEvent ? { kind: errorEvent.kind, message: errorEvent.message, retryable: errorEvent.retryable } : undefined,
        };
    }

    async close(): Promise<void> {
        this.child.stdin.end();
        await this.child.exited;
    }

    private async readEvents(): Promise<void> {
        const decoder = new TextDecoder();
        let buffered = "";
        for await (const chunk of this.child.stdout) {
            const receivedAtMs = performance.now();
            buffered += decoder.decode(chunk, { stream: true });
            let newlineIndex: number;
            while ((newlineIndex = buffered.indexOf("\n")) >= 0) {
                const event = JSON.parse(buffered.slice(0, newlineIndex));
                buffered = buffered.slice(newlineIndex + 1);
                const events = this.eventsByRequest.get(event.re) ?? [];
                events.push({ event, receivedAtMs });
                this.eventsByRequest.set(event.re, events);
                if (event.ev === "done" || event.ev === "error") this.waiters.get(event.re)?.();
            }
        }
    }
}

export function percentile(values: number[], fraction: number): number | undefined {
    if (values.length === 0) return undefined;
    const sorted = [...values].sort((first, second) => first - second);
    return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
}

export function option(name: string, fallback: string): string {
    const index = process.argv.indexOf(`--${name}`);
    return index >= 0 && process.argv[index + 1] !== undefined ? process.argv[index + 1] : fallback;
}
