// Scoring rules of the S1 vision probe (§15 S1, §7.4 capability guard).
import { describe, expect, test } from "bun:test";
import { scoreProbeAnswer, type ProbeImage } from "../scripts/vision-probe-common";

const probe: ProbeImage = { path: "unused", words: ["KESTREL", "MAPLE", "ORBIT"], number: "4831" };

describe("scoreProbeAnswer", () => {
    test("all labels and the number → sees", () => {
        expect(scoreProbeAnswer('{"1":"Kestrel","2":"maple","3":"ORBIT.","number":"#4831"}', probe).verdict).toBe("sees");
    });
    test("a text-only model answering nulls or guesses → blind", () => {
        expect(scoreProbeAnswer('{"1":null,"2":null,"3":null,"number":null}', probe).verdict).toBe("blind");
        expect(scoreProbeAnswer('Sure! {"1":"APPLE","2":"BANANA","3":"CHERRY","number":"1234"}', probe).verdict).toBe("blind");
    });
    test("some right → partial (still a failure for a candidate)", () => {
        expect(scoreProbeAnswer('{"1":"KESTREL","2":"MAPLE","3":"ORBIT","number":"4881"}', probe)).toMatchObject({ verdict: "partial", labelsCorrect: 3 });
    });
    test("no JSON → unparsed", () => {
        expect(scoreProbeAnswer("[Image attached — this model cannot view images]", probe).verdict).toBe("unparsed");
    });
});
