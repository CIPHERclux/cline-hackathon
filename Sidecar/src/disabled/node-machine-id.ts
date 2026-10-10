// Stand-in for `node-machine-id`, swapped in at build time by scripts/build-bin.ts. The SDK only
// wants a machine id to label telemetry, and reading it shells out to `ioreg` for the Mac's
// hardware UUID. Chalk sends no telemetry (§10.1, D32), so there is no id: the SDK falls back
// to a random id stored under CLINE_DIR.
export function machineIdSync(): string {
    return "";
}
export async function machineId(): Promise<string> {
    return "";
}
export default { machineIdSync, machineId };
