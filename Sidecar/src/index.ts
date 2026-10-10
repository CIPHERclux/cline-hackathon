// tutor-engine: the Cline sidecar (§7.3). Reads NDJSON requests on stdin, writes NDJSON events
// on stdout, logs to stderr. The Swift app owns the process lifecycle (launch, ping while
// active, restart with backoff, dispose → SIGTERM → SIGKILL).
import { homedir } from "node:os";
import { join } from "node:path";
import type { EngineEvent } from "./protocol";

// §10.1: everything the SDK writes (auth tokens, transcripts) is readable by the owner only.
process.umask(0o077);

// §7.3 Launch: the SDK keeps sessions and auth under CLINE_DIR. Swift sets it; default to the
// app's Application Support folder so a hand-run binary never writes to ~/.cline. It must be
// set before the SDK is loaded, hence the dynamic imports below.
process.env.CLINE_DIR ??= join(homedir(), "Library", "Application Support", "Chalk", "cline");
const clineDirectory = process.env.CLINE_DIR;

const { Engine } = await import("./engine");
const { parseRequestLine } = await import("./protocol");

function writeEvent(event: EngineEvent): void {
    process.stdout.write(`${JSON.stringify(event)}\n`);
}

const engine = new Engine(writeEvent, process.env, clineDirectory);

let shuttingDown = false;
async function shutDown(exitCode: number): Promise<never> {
    if (!shuttingDown) {
        shuttingDown = true;
        await engine.dispose().catch((error) => console.error("dispose failed:", error));
    }
    process.exit(exitCode);
}
process.on("SIGTERM", () => void shutDown(0));
process.on("SIGINT", () => void shutDown(0));

// Requests are handled concurrently: an `abort` or steering `send` must reach a turn that is
// still streaming.
for await (const line of console) {
    if (line.trim().length === 0) continue;
    const request = parseRequestLine(line);
    if ("invalid" in request) {
        writeEvent({ re: request.id, ev: "error", kind: "internal", retryable: false, message: request.invalid });
        continue;
    }
    void engine.handle(request);
}

// stdin closed: the app quit or crashed. Don't linger as an orphan.
await shutDown(0);
