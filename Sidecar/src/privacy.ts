import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// §10.1: a screenshot leaves the Mac only for the turn it was taken for, and is "never written
// to disk unless the learner saves/pins". §7.4: "Screenshots from earlier turns are dropped
// from history". ClineCore keeps every image in its in-memory history (resending it each turn)
// and in plain-file session storage (measured in S01), so the engine enforces both itself (D39).

export const REMOVED_SCREENSHOT_TEXT = "[earlier screenshot removed]";

type MessageLike = { role?: string; content?: unknown };

function isImagePart(part: unknown): boolean {
    return typeof part === "object" && part !== null && (part as { type?: unknown }).type === "image";
}

function withoutImages(message: MessageLike): MessageLike {
    if (!Array.isArray(message.content) || !message.content.some(isImagePart)) return message;
    return {
        ...message,
        content: message.content.map((part) => (isImagePart(part) ? { type: "text", text: REMOVED_SCREENSHOT_TEXT } : part)),
    };
}

// The model sees only the images of the most recent user message that has any: the screen
// the current question is about. A steer or a follow-up without a new capture keeps it; a new
// capture replaces it. Returns undefined when nothing needs to change.
export function dropEarlierScreenshots<Message extends MessageLike>(messages: readonly Message[]): Message[] | undefined {
    let latestImageMessageIndex = -1;
    for (let index = messages.length - 1; index >= 0; index--) {
        const content = messages[index].content;
        if (messages[index].role === "user" && Array.isArray(content) && content.some(isImagePart)) {
            latestImageMessageIndex = index;
            break;
        }
    }
    let changed = false;
    const result = messages.map((message, index) => {
        if (index === latestImageMessageIndex) return message;
        const stripped = withoutImages(message);
        if (stripped !== message) changed = true;
        return stripped as Message;
    });
    return changed ? result : undefined;
}

// Rewrites one persisted transcript (`<CLINE_DIR>/data/sessions/<id>/<id>.messages.json`) with
// every image replaced by a placeholder. Text stays: transcripts are kept locally until the
// session is deleted (§10.1). Returns true when the file changed.
export function scrubScreenshotsFromMessagesFile(messagesFile: string): boolean {
    try {
        const stored = JSON.parse(readFileSync(messagesFile, "utf8"));
        if (!Array.isArray(stored?.messages)) return false;
        let changed = false;
        stored.messages = stored.messages.map((message: MessageLike) => {
            const stripped = withoutImages(message);
            if (stripped !== message) changed = true;
            return stripped;
        });
        if (changed) writeFileSync(messagesFile, JSON.stringify(stored, null, 2), { mode: 0o600 });
        return changed;
    } catch (error) {
        console.error(`could not scrub screenshots from ${messagesFile}:`, error);
        return false;
    }
}

// Crash recovery at startup: a crash between the SDK's write and our scrub could leave one.
export function scrubScreenshotsFromAllSessionFiles(clineDirectory: string): number {
    const sessionsDirectory = join(clineDirectory, "data", "sessions");
    if (!existsSync(sessionsDirectory)) return 0;
    let scrubbedFileCount = 0;
    for (const sessionId of readdirSync(sessionsDirectory)) {
        const messagesFile = join(sessionsDirectory, sessionId, `${sessionId}.messages.json`);
        if (existsSync(messagesFile) && scrubScreenshotsFromMessagesFile(messagesFile)) scrubbedFileCount += 1;
    }
    return scrubbedFileCount;
}
