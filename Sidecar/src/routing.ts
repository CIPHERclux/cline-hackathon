import type { SlotName } from "./protocol";
// Bundled into the compiled binary so the engine has no runtime file dependency (§7.4: slots are
// config, not code; the file stays the single place to change model IDs).
import modelRoutingConfig from "../model-routing.json";

export type SlotModel = { providerId: string; modelId: string; apiKey?: string; baseUrl?: string };

type ProfileConfig = {
    providerId: string;
    apiKey?: string;
    apiKeyEnv?: string;
    baseUrlEnv?: string;
    slots: Record<SlotName, { primary: string; fallbacks: string[] }>;
};

// The profile is picked by env so the same binary serves the demo (Cline credits), development
// on a free provider, and tests (D37). Unknown profiles fail loudly instead of silently using
// the demo models.
export function resolveSlotModel(
    slot: SlotName,
    environment: Record<string, string | undefined>,
    modelOverride?: string,
): SlotModel {
    const profiles = modelRoutingConfig.profiles as Record<string, ProfileConfig>;
    const profileName = environment.CHALK_MODEL_PROFILE ?? modelRoutingConfig.defaultProfile;
    const profile = profiles[profileName];
    if (!profile) throw new Error(`unknown model profile "${profileName}"`);
    const slotConfig = profile.slots[slot];
    if (!slotConfig) throw new Error(`profile "${profileName}" has no slot "${slot}"`);

    const apiKey = profile.apiKeyEnv ? environment[profile.apiKeyEnv] : profile.apiKey;
    if (profile.apiKeyEnv && !apiKey) throw new Error(`profile "${profileName}" needs env ${profile.apiKeyEnv}`);
    const baseUrl = profile.baseUrlEnv ? environment[profile.baseUrlEnv] : undefined;
    if (profile.baseUrlEnv && !baseUrl) throw new Error(`profile "${profileName}" needs env ${profile.baseUrlEnv}`);

    return { providerId: profile.providerId, modelId: modelOverride ?? slotConfig.primary, apiKey, baseUrl };
}
