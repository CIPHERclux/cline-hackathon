import type { ErrorKind } from "./protocol";

export type ClassifiedError = { kind: ErrorKind; retryable: boolean; message: string };

// Region/availability refusals are 403s that another model or provider may not have, so the
// Swift router should fall back instead of asking the learner to sign in again (§11.4 P-REGION).
const REGION_REFUSAL = /region|country|location|not available in your|unsupported_country/i;
// A model id the provider doesn't (yet) serve: another model can answer, so the router falls back
// instead of failing the turn (D73: Haiku 5.5 primary, Haiku 4.5 fallback).
const MODEL_UNAVAILABLE = /model[^.]{0,60}(not found|does not exist|doesn't exist|unknown|invalid|not supported|unsupported|unavailable|not available)|no such model|unknown model|invalid model/i;

// Maps a provider HTTP status onto the §7.3 error kinds. `retryable` tells the Swift router
// whether trying again (same or fallback model) can help.
export function classifyHttpStatus(status: number, bodyText: string): ClassifiedError {
    const message = summarizeBody(bodyText) || `provider returned HTTP ${status}`;
    if (status === 401) return { kind: "auth", retryable: false, message };
    if (status === 403) {
        return REGION_REFUSAL.test(bodyText)
            ? { kind: "model", retryable: true, message }
            : { kind: "auth", retryable: false, message };
    }
    if (status === 429) return { kind: "rate_limit", retryable: true, message };
    if (status >= 500) return { kind: "model", retryable: true, message };
    return { kind: "model", retryable: MODEL_UNAVAILABLE.test(bodyText), message };
}

// The SDK only knows "auth" | "context_window_exceeded" | "unknown" (@cline/shared
// ProviderErrorClass), so connection failures are recognised from the message.
export function classifySdkError(errorClass: string | undefined, error: unknown): ClassifiedError {
    const message = error instanceof Error ? error.message : String(error ?? "unknown error");
    if (errorClass === "auth") return { kind: "auth", retryable: false, message };
    if (errorClass === "context_window_exceeded") return { kind: "model", retryable: true, message };
    if (/Cannot connect|Unable to connect|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|network/i.test(message)) {
        return { kind: "network", retryable: true, message };
    }
    if (MODEL_UNAVAILABLE.test(message)) return { kind: "model", retryable: true, message };
    return { kind: "internal", retryable: false, message };
}

function summarizeBody(bodyText: string): string {
    try {
        const parsed = JSON.parse(bodyText);
        const message = parsed?.error?.message ?? parsed?.message;
        if (typeof message === "string") return message.slice(0, 300);
    } catch {}
    return bodyText.slice(0, 300);
}
