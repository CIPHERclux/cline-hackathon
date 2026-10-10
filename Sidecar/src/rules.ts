import { mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import teacherRules from "../resources/clinerules/00-teacher.md" with { type: "text" };
import teachingScriptRules from "../resources/clinerules/10-teaching-script.md" with { type: "text" };
import groundingRules from "../resources/clinerules/20-grounding.md" with { type: "text" };
import safetyRules from "../resources/clinerules/30-safety.md" with { type: "text" };
import walkthroughRules from "../resources/clinerules/40-walkthrough.md" with { type: "text" };

// §7.5: the persona, script format, grounding, safety and walkthrough rules are Cline rules, not
// code. ClineCore appends every file in <CLINE_DIR>/rules to the system prompt (verified in S04),
// so the engine installs the copies bundled into this binary at launch. Rewriting them each time
// keeps the rules in step with the binary and drops stale files from older versions.
const BUNDLED_RULES: Record<string, string> = {
    "00-teacher.md": teacherRules,
    "10-teaching-script.md": teachingScriptRules,
    "20-grounding.md": groundingRules,
    "30-safety.md": safetyRules,
    "40-walkthrough.md": walkthroughRules,
};

export function installTeacherRules(clineDirectory: string): void {
    const rulesDirectory = join(clineDirectory, "rules");
    mkdirSync(rulesDirectory, { recursive: true });
    for (const existing of readdirSync(rulesDirectory)) {
        if (!(existing in BUNDLED_RULES)) rmSync(join(rulesDirectory, existing), { force: true });
    }
    for (const [fileName, contents] of Object.entries(BUNDLED_RULES)) {
        writeFileSync(join(rulesDirectory, fileName), contents, { mode: 0o600 });
    }
}
