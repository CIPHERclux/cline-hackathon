// Runs the real engine (`src/index.ts`) as a child process and talks the §7.3 NDJSON protocol
// to it over stdio, exactly as the Swift app will.
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SIDECAR_DIRECTORY = join(import.meta.dir, "..");

export type EngineEventRecord = { event: any; receivedAt: number };

export class EngineProcess {
    readonly events: EngineEventRecord[] = [];
    clineDirectory = "";
    stderrText = "";
    private readonly child: ReturnType<typeof Bun.spawn>;

    private constructor(command: string[], environment: Record<string, string>) {
        this.child = Bun.spawn(command, {
            cwd: SIDECAR_DIRECTORY,
            env: environment,
            stdin: "pipe",
            stdout: "pipe",
            stderr: "pipe",
        });
        void this.readLines(this.child.stdout as ReadableStream<Uint8Array>, (line) => {
            this.events.push({ event: JSON.parse(line), receivedAt: performance.now() });
        });
        void this.readLines(this.child.stderr as ReadableStream<Uint8Array>, (line) => {
            this.stderrText += `${line}\n`;
        });
    }

    // A scrubbed environment like the Swift launcher's (§7.3 Launch): no inherited secrets.
    static launch(extraEnvironment: Record<string, string>): EngineProcess {
        const clineDirectory = mkdtempSync(join(tmpdir(), "chalk-cline-test-"));
        // CHALK_ENGINE_BINARY runs the suite against the compiled `dist/tutor-engine` instead of
        // the sources. The network guard can only be preloaded into the sources.
        const command: string[] = process.env.CHALK_ENGINE_BINARY
            ? [process.env.CHALK_ENGINE_BINARY]
            : ["bun", "--preload", "./test/net-guard.ts", "src/index.ts"];
        const engine = new EngineProcess(command, {
            PATH: process.env.PATH ?? "/usr/bin:/bin",
            HOME: process.env.HOME ?? tmpdir(),
            CLINE_DIR: clineDirectory,
            CHALK_MODEL_PROFILE: "stub",
            ...extraEnvironment,
        });
        engine.clineDirectory = clineDirectory;
        return engine;
    }

    send(request: Record<string, unknown>): number {
        const sentAt = performance.now();
        const stdin = this.child.stdin as import("bun").FileSink;
        stdin.write(`${JSON.stringify(request)}\n`);
        stdin.flush();
        return sentAt;
    }

    // Latency checks use each record's `receivedAt`, not the moment this poll notices it.
    async waitFor(predicate: (event: any) => boolean, timeoutMs = 5_000): Promise<EngineEventRecord> {
        const deadline = performance.now() + timeoutMs;
        for (;;) {
            const match = this.events.find((record) => predicate(record.event));
            if (match) return match;
            if (performance.now() > deadline) {
                throw new Error(
                    `timed out; events so far:\n${this.events.map((r) => JSON.stringify(r.event)).join("\n")}\nstderr:\n${this.stderrText}`,
                );
            }
            await Bun.sleep(2);
        }
    }

    eventsFor(requestId: string): any[] {
        return this.events.map((record) => record.event).filter((event) => event.re === requestId);
    }

    async close(): Promise<number> {
        (this.child.stdin as import("bun").FileSink).end();
        return await this.child.exited;
    }

    private async readLines(stream: ReadableStream<Uint8Array>, onLine: (line: string) => void): Promise<void> {
        const decoder = new TextDecoder();
        let buffered = "";
        for await (const chunk of stream) {
            buffered += decoder.decode(chunk, { stream: true });
            let newlineIndex: number;
            while ((newlineIndex = buffered.indexOf("\n")) >= 0) {
                const line = buffered.slice(0, newlineIndex);
                buffered = buffered.slice(newlineIndex + 1);
                if (line.trim()) onLine(line);
            }
        }
    }
}
