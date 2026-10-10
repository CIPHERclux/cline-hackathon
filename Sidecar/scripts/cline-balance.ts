// Prints the signed-in Cline account's credit balance (D10), so credit spend can be checked
// before and after a probe run. Reads the sign-in from CLINE_DIR like tutor-engine.
// Usage: bun Sidecar/scripts/cline-balance.ts
import { homedir } from "node:os";
import { join } from "node:path";

process.env.CLINE_DIR ??= join(homedir(), "Library", "Application Support", "Chalk", "cline");
const { ClineAccountService, getPersistedProviderApiKey, ProviderSettingsManager } = await import("@cline/sdk");

const settings = new ProviderSettingsManager().getProviderSettings("cline");
const token = getPersistedProviderApiKey("cline", settings);
if (!token) {
    console.error("Not signed in: run bun Sidecar/scripts/cline-login.ts");
    process.exit(1);
}
const account = new ClineAccountService({ apiBaseUrl: "https://api.cline.bot", getAuthToken: async () => token });
const me = await account.fetchMe();
const balance = await account.fetchBalance(me.id);
console.log(`${me.email}: balance ${JSON.stringify(balance.balance)}`);
