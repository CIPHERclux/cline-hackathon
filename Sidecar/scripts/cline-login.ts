// One-time Cline sign-in for the `demo` profile (§7.3 "Auth & keys", D10): the SDK's own OAuth
// flow (local callback on ports 48801–48811), saving the tokens into CLINE_DIR, the same folder
// tutor-engine reads. Run it in a terminal; it prints a URL to open in the browser.
//
// Usage: bun Sidecar/scripts/cline-login.ts            (default CLINE_DIR: ~/Library/Application Support/Chalk/cline)
import { homedir } from "node:os";
import { join } from "node:path";

// §10.1: the token files are owner-only.
process.umask(0o077);
process.env.CLINE_DIR ??= join(homedir(), "Library", "Application Support", "Chalk", "cline");
const { loginAndSaveProviderOAuthCredentials, ProviderSettingsManager } = await import("@cline/sdk");

const manager = new ProviderSettingsManager();
console.log(`Saving the Cline sign-in to ${manager.getFilePath()}`);

const settings = await loginAndSaveProviderOAuthCredentials(manager, "cline", {
    callbacks: {
        onAuth: ({ url, instructions }) => {
            console.log(`\nOpen this link in your browser and sign in to Cline:\n\n  ${url}\n`);
            if (instructions) console.log(instructions);
        },
        onPrompt: async (prompt) => {
            process.stdout.write(`${prompt.message} `);
            for await (const line of console) return line.trim();
            return "";
        },
        onProgress: (message) => console.log(message),
    },
});

const userInfo = (settings.auth as { metadata?: { userInfo?: { email?: string } } } | undefined)?.metadata?.userInfo;
console.log(`\nSigned in${userInfo?.email ? ` as ${userInfo.email}` : ""}. tutor-engine's demo profile will use this account.`);
process.exit(0);
