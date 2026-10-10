// Compiles tutor-engine into one executable (§7.3 Process model: `bun build --compile`).
// Two SDK dependencies are swapped for local stand-ins (D32): the optional `posthog-node` peer
// (missing, and telemetry anyway) and `node-machine-id` (hardware UUID via `ioreg`).
import { join } from "node:path";

const sidecarDirectory = join(import.meta.dir, "..");

const result = await Bun.build({
    entrypoints: [join(sidecarDirectory, "src/index.ts")],
    compile: { outfile: join(sidecarDirectory, "dist/tutor-engine") },
    minify: true,
    sourcemap: "linked",
    plugins: [
        {
            name: "disable-telemetry-dependencies",
            setup(build) {
                build.onResolve({ filter: /^(posthog-node|node-machine-id)$/ }, (args) => ({
                    path: join(sidecarDirectory, `src/disabled/${args.path}.ts`),
                }));
            },
        },
    ],
});

if (!result.success) {
    for (const message of result.logs) console.error(message);
    process.exit(1);
}
for (const output of result.outputs) console.log(`built ${output.path} (${(output.size / 1e6).toFixed(1)} MB)`);
