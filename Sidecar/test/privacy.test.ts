// Unit tests for the screenshot-dropping rule (§7.4, D39).
import { describe, expect, test } from "bun:test";
import { dropEarlierScreenshots, REMOVED_SCREENSHOT_TEXT } from "../src/privacy";

const image = (tag: string) => ({ type: "image", image: tag });
const text = (value: string) => ({ type: "text", text: value });

describe("dropEarlierScreenshots", () => {
    test("leaves a single-turn request alone", () => {
        expect(dropEarlierScreenshots([{ role: "user", content: [text("q"), image("A")] }])).toBeUndefined();
    });

    test("keeps only the latest user message's images", () => {
        const result = dropEarlierScreenshots([
            { role: "user", content: [text("q1"), image("A")] },
            { role: "assistant", content: [text("a1")] },
            { role: "user", content: [text("q2"), image("B")] },
        ]);
        expect(result?.[0].content).toEqual([text("q1"), text(REMOVED_SCREENSHOT_TEXT)]);
        expect(result?.[2].content).toEqual([text("q2"), image("B")]);
    });

    test("a later message without images keeps the current screen", () => {
        expect(
            dropEarlierScreenshots([
                { role: "user", content: [text("q1"), image("A")] },
                { role: "assistant", content: [text("a1")] },
                { role: "user", content: [text("steer")] },
            ]),
        ).toBeUndefined();
    });

    test("string contents and messages without images pass through", () => {
        expect(dropEarlierScreenshots([{ role: "system", content: "persona" }, { role: "user", content: "hi" }])).toBeUndefined();
    });
});
