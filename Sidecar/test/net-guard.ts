// Preloaded into the engine under test (`bun --preload`). Any connection that is not to the
// local stub is blocked and reported on stderr as `NETGUARD`, so the contract test can prove
// the SDK makes no telemetry, feature-flag or catalog calls during a session (D32, §10.1).
import net from "node:net";
import tls from "node:tls";

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);

function report(target: string): void {
    process.stderr.write(`NETGUARD blocked ${target}\n`);
}

const originalFetch = globalThis.fetch;
globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (!LOOPBACK_HOSTS.has(url.hostname)) {
        report(url.href);
        throw new Error(`net-guard: blocked ${url.host}`);
    }
    return originalFetch(input, init);
}) as typeof fetch;

function guardConnect(original: (...args: any[]) => any) {
    return function (this: unknown, ...args: any[]) {
        const options = typeof args[0] === "object" && args[0] !== null ? args[0] : { port: args[0], host: args[1] };
        const host = options.host ?? options.hostname ?? "localhost";
        if (options.path === undefined && !LOOPBACK_HOSTS.has(String(host))) {
            report(`${host}:${options.port}`);
            throw new Error(`net-guard: blocked ${host}`);
        }
        return original.apply(this, args);
    };
}
(net as any).connect = guardConnect(net.connect);
(net as any).createConnection = guardConnect(net.createConnection);
(tls as any).connect = guardConnect(tls.connect);
