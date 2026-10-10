// Stand-in for the SDK's optional `posthog-node` peer dependency, swapped in at build time by
// scripts/build-bin.ts. Chalk sends no telemetry (§10.1, §11.6, D32): if the SDK ever tried to
// start its feature-flag client, construction fails instead of contacting data.cline.bot.
export class PostHog {
    constructor() {
        throw new Error("PostHog is disabled in tutor-engine (D32)");
    }
}
export default PostHog;
