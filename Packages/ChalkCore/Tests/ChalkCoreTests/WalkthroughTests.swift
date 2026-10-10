import CoreGraphics
import Foundation
import Testing

@testable import ChalkCore

@Suite("Walkthrough intent and commands (§4.2.6)")
struct WalkthroughIntentTests {
    @Test("procedures are walkthroughs")
    func procedures() {
        #expect(WalkthroughIntent.isWalkthroughRequest("Guide me how to colour grade this"))
        #expect(
            WalkthroughIntent.isWalkthroughRequest(
                "can you walk me through exporting this for YouTube"))
        #expect(
            WalkthroughIntent.isWalkthroughRequest("help me make a pivot table of sales by region"))
        #expect(WalkthroughIntent.isWalkthroughRequest("help me set up a VPN"))
        #expect(WalkthroughIntent.isWalkthroughRequest("how do I add a keyframe, step by step"))
        #expect(WalkthroughIntent.isWalkthroughRequest("teach me how to use auto layout"))
    }

    @Test("tasks said plainly are walkthroughs (D69)")
    func plainTasks() {
        #expect(WalkthroughIntent.isWalkthroughRequest("Guide how to turn on Dark Mode."))
        #expect(WalkthroughIntent.isWalkthroughRequest("I have to write a mail. What should I do?"))
        #expect(WalkthroughIntent.isWalkthroughRequest("I need to share this folder with Sam"))
        #expect(WalkthroughIntent.isWalkthroughRequest("how do I export this as a PDF"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("I need to understand this chart"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("what does open source mean"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("how do I bold text"))
    }

    @Test("maths, questions and 'make sense' are not")
    func notProcedures() {
        #expect(!WalkthroughIntent.isWalkthroughRequest("solve this question step by step"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("walk me through this proof and derive it"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("where is the export button"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("help me make sense of this chart"))
        #expect(!WalkthroughIntent.isWalkthroughRequest("what does this error mean"))
    }

    @Test("short utterances are commands")
    func commands() {
        #expect(WalkthroughCommand.parse("Next") == .next)
        #expect(WalkthroughCommand.parse("okay, done") == .next)
        #expect(WalkthroughCommand.parse("I did it") == .next)
        #expect(WalkthroughCommand.parse("skip this one") == .skip)
        #expect(WalkthroughCommand.parse("go back") == .back)
        #expect(WalkthroughCommand.parse("start over") == .startOver)
        #expect(WalkthroughCommand.parse("stop") == .stop)
        #expect(WalkthroughCommand.parse("say that again") == .repeatStep)
        #expect(WalkthroughCommand.parse("why?") == .why)
    }

    @Test("how-to titles drop the request words")
    func titles() {
        #expect(
            WalkthroughIntent.taskTitle(from: "Guide me how to colour grade this.")
                == "Colour grade this")
        #expect(
            WalkthroughIntent.taskTitle(
                from: "can you help me make a pivot table of sales by region")
                == "Make a pivot table of sales by region")
        #expect(
            WalkthroughIntent.taskTitle(from: "walk me through setting up a VPN")
                == "Setting up a VPN")
        #expect(WalkthroughIntent.taskTitle(from: "Export for YouTube") == "Export for YouTube")
    }

    @Test("questions are not commands")
    func questions() {
        #expect(WalkthroughCommand.parse("what does Lift actually do?") == nil)
        #expect(WalkthroughCommand.parse("how do I know when the blacks are right") == nil)
        #expect(
            WalkthroughCommand.parse("can you explain the difference between gamma and gain please")
                == nil)
    }
}

@Suite("Keyboard shortcuts")
struct KeyboardShortcutTests {
    @Test("the ways plans write shortcuts")
    func parsing() {
        #expect(KeyboardShortcut(parsing: "⌥S") == KeyboardShortcut(modifiers: [.option], key: "s"))
        #expect(
            KeyboardShortcut(parsing: "Option-S")
                == KeyboardShortcut(modifiers: [.option], key: "s"))
        #expect(
            KeyboardShortcut(parsing: "Shift+D") == KeyboardShortcut(modifiers: [.shift], key: "d"))
        #expect(
            KeyboardShortcut(parsing: "⇧⌘W")
                == KeyboardShortcut(modifiers: [.shift, .command], key: "w"))
        #expect(
            KeyboardShortcut(parsing: "Cmd Shift W")
                == KeyboardShortcut(modifiers: [.shift, .command], key: "w"))
        #expect(
            KeyboardShortcut(parsing: "Return") == KeyboardShortcut(modifiers: [], key: "return"))
        #expect(KeyboardShortcut(parsing: "drag the wheel") == nil)
    }

    @Test("matching needs the same modifiers")
    func matching() {
        let shortcut = KeyboardShortcut(parsing: "⌥S")!
        #expect(shortcut.matches(key: "S", modifiers: [.option]))
        #expect(!shortcut.matches(key: "s", modifiers: [.option, .shift]))
        #expect(!shortcut.matches(key: "s", modifiers: []))
        #expect(shortcut.symbols == "⌥S")
        #expect(KeyboardShortcut(parsing: "⇧⌘W")!.spoken == "Shift Command W")
    }
}

@Suite("Accessibility matching (D74)")
struct AccessibilityMatchingTests {
    let snapshot = AccessibilitySnapshot(
        appName: "Mail", bundleIdentifier: "com.apple.mail", focusedWindowTitle: "New Message",
        documentURL: nil,
        nodes: [
            AccessibilityNode(
                role: "AXButton", label: "Compose",
                frame: CGRect(x: 10, y: 10, width: 30, height: 30)),
            AccessibilityNode(
                role: "AXStaticText", value: "Subject:",
                frame: CGRect(x: 10, y: 100, width: 60, height: 20)),
            AccessibilityNode(
                role: "AXTextField", label: "Subject", value: "Lunch on Friday",
                frame: CGRect(x: 80, y: 100, width: 400, height: 22)),
            AccessibilityNode(
                role: "AXTextField", label: "To", value: "",
                frame: CGRect(x: 80, y: 70, width: 400, height: 22), isFocused: true),
            AccessibilityNode(
                role: "AXPopUpButton", title: "Trip type", value: "One way",
                frame: CGRect(x: 10, y: 200, width: 90, height: 24)),
            AccessibilityNode(
                role: "AXButton", title: "Send",
                frame: CGRect(x: 500, y: 10, width: 40, height: 24), isEnabled: false),
        ])

    @Test("a query finds the control by name and role")
    func bestMatch() {
        let compose = AccessibilityMatcher.bestMatch(
            for: ElementQuery(role: .button, name: "Compose"), in: snapshot, visibleArea: nil)
        #expect(compose?.label == "Compose")
        let subject = AccessibilityMatcher.bestMatch(
            for: ElementQuery(role: .field, name: "Subject"), in: snapshot, visibleArea: nil)
        #expect(subject?.role == "AXTextField")
        #expect(
            AccessibilityMatcher.bestMatch(
                for: ElementQuery(role: .button, name: "Archive"), in: snapshot, visibleArea: nil)
                == nil)
    }

    @Test("a guessed point snaps to the smallest element under it")
    func snap() {
        #expect(
            AccessibilityMatcher.smallestElement(containing: CGPoint(x: 25, y: 25), in: snapshot)?
                .label == "Compose")
    }

    @Test("the planner gets the controls as role, name lines")
    func controls() {
        let summary = WalkthroughPrompts.controlsSummary(snapshot) ?? ""
        #expect(summary.contains("button, Compose"))
        #expect(summary.contains("field, To (focused)"))
        #expect(summary.contains("popup, Trip type"))
    }
}

@Suite("Done predicates (D74)")
struct DonePredicateTests {
    let snapshot = AccessibilityMatchingTests().snapshot

    func check(_ json: String, visibleTexts: [String]? = nil) -> Bool? {
        DonePredicate(json: JSONValue.parse(json)!)?.evaluate(
            snapshot: snapshot, frontmostAppName: "Mail", visibleTexts: visibleTexts)
    }

    @Test("predicates read the tree")
    func tree() {
        #expect(check(#"{"focused":"To"}"#) == true)
        #expect(check(#"{"focused":"Subject"}"#) == false)
        #expect(check(#"{"value_not_empty":"Subject"}"#) == true)
        #expect(check(#"{"value_not_empty":"To"}"#) == false)
        #expect(check(#"{"value_contains":{"name":"Subject","text":"friday"}}"#) == true)
        #expect(check(#"{"window":"New Message"}"#) == true)
        #expect(check(#"{"exists":"Compose"}"#) == true)
        #expect(check(#"{"gone":"Compose"}"#) == false)
        #expect(check(#"{"selected":"One way"}"#) == true)
        #expect(check(#"{"app":"Mail"}"#) == true)
        #expect(check(#"{"all":[{"app":"Mail"},{"focused":"Subject"}]}"#) == false)
        #expect(check(#"{"any":[{"focused":"Subject"},{"focused":"To"}]}"#) == true)
    }

    @Test("without a usable tree the answer is unknown, except what OCR can show")
    func noTree() {
        let empty = AccessibilitySnapshot(
            appName: "DaVinci Resolve", bundleIdentifier: nil, focusedWindowTitle: nil,
            documentURL: nil, nodes: [])
        let focused = DonePredicate.focused("Lift").evaluate(
            snapshot: empty, frontmostAppName: "DaVinci Resolve", visibleTexts: nil)
        #expect(focused == nil)
        let text = DonePredicate.text("Color").evaluate(
            snapshot: empty, frontmostAppName: "DaVinci Resolve", visibleTexts: ["Color", "Edit"])
        #expect(text == true)
        let anyUnknown = DonePredicate.any([.focused("Lift"), .app("Finder")]).evaluate(
            snapshot: empty, frontmostAppName: "DaVinci Resolve", visibleTexts: nil)
        #expect(anyUnknown == nil)
    }

    @Test("a browser URL")
    func url() {
        let browser = AccessibilitySnapshot(
            appName: "Google Chrome", bundleIdentifier: nil, focusedWindowTitle: "Google Flights",
            documentURL: "https://www.google.com/travel/flights", nodes: snapshot.nodes)
        #expect(
            DonePredicate.url("google.com/travel/flights").evaluate(
                snapshot: browser, frontmostAppName: "Google Chrome", visibleTexts: nil) == true)
    }
}

@Suite("Walkthrough checks and polling")
struct WalkthroughCheckTests {
    @Test("keys become typing, commits and shortcuts")
    func keyTriggers() {
        #expect(WalkthroughCheckPolicy.trigger(forKey: "h", modifiers: []) == .typing)
        #expect(WalkthroughCheckPolicy.trigger(forKey: "return", modifiers: []) == .returnKey)
        #expect(
            WalkthroughCheckPolicy.trigger(forKey: "n", modifiers: [.command]) == .shortcut("⌘N"))
        #expect(WalkthroughCheckPolicy.trigger(forKey: "escape", modifiers: []) == nil)
    }

    @Test("tile diff measures the changed share")
    func tileDiff() {
        let blank = ScreenThumbnail(
            luminance: [UInt8](repeating: 20, count: ScreenThumbnail.columns * ScreenThumbnail.rows)
        )
        var changedPixels = blank.luminance
        for row in 0..<10 {
            for column in 32..<64 { changedPixels[row * ScreenThumbnail.columns + column] = 200 }
        }
        let change = ScreenChange.between(blank, ScreenThumbnail(luminance: changedPixels))
        #expect(abs(change.changedFraction - 0.125) < 0.001)
    }

    @Test("the fast-path check and locate replies parse")
    func replies() {
        #expect(
            WalkthroughPrompts.checkResult(in: #"{"done":true,"on_track":true}"#)
                == .init(done: true, onTrack: true))
        #expect(
            WalkthroughPrompts.checkResult(
                in: "```json\n{\"done\": false, \"on_track\": false}\n```")
                == .init(done: false, onTrack: false))
        #expect(
            WalkthroughPrompts.checkResult(in: #"{"done":false}"#)
                == .init(done: false, onTrack: nil))
        #expect(WalkthroughPrompts.checkResult(in: "maybe") == nil)
        #expect(WalkthroughPrompts.locatedPoint(in: #"{"px":[512,88]}"#) == CGPoint(x: 512, y: 88))
        #expect(WalkthroughPrompts.locatedPoint(in: #"{"none":true}"#) == nil)
    }

    @Test("the plan context lists controls and a saved path")
    func planningContext() {
        let context = WalkthroughPrompts.planningContext(
            appName: "Mail", controls: "button, Compose", openApps: ["Mail", "Google Chrome"],
            savedSteps: [WalkthroughStep(kind: .click, instruction: "Click Compose.")])
        #expect(context.contains("mode=\"plan\""))
        #expect(context.contains("button, Compose"))
        #expect(context.contains("Apps already open: Mail, Google Chrome."))
        #expect(context.contains("1. Click Compose."))
    }
}

@Suite("Leaving the plan (D75)")
struct WalkthroughNavigatorTests {
    @Test("a later step that became done is a jump; one that was already done isn't")
    func jumps() {
        #expect(
            WalkthroughNavigator.jumpTarget(
                currentIndex: 1, baseline: [2: false, 3: false, 4: true],
                now: [2: true, 3: true, 4: true]) == 3)
        #expect(
            WalkthroughNavigator.jumpTarget(currentIndex: 1, baseline: [2: true], now: [2: true])
                == nil)
        #expect(
            WalkthroughNavigator.jumpTarget(currentIndex: 1, baseline: [2: false], now: [2: false])
                == nil)
    }

    @Test("transient predicates never autonomously undo verified history (D84)")
    func regression() {
        #expect(!WalkthroughNavigator.canRegress(.focused("To")))
        #expect(!WalkthroughNavigator.canRegress(.window("New Message")))
        #expect(!WalkthroughNavigator.canRegress(.all([.focused("To")])))
        #expect(!WalkthroughNavigator.canRegress(.any([.focused("To"), .exists("Sent")])))
    }

    @Test("dialogs and sheets are found with their words")
    func dialogs() {
        let snapshot = AccessibilitySnapshot(
            appName: "Mail", bundleIdentifier: nil, focusedWindowTitle: nil, documentURL: nil,
            nodes: [
                AccessibilityNode(
                    role: "AXSheet", frame: CGRect(x: 100, y: 100, width: 300, height: 150)),
                AccessibilityNode(
                    role: "AXStaticText", value: "Save changes?",
                    frame: CGRect(x: 120, y: 120, width: 120, height: 20)),
                AccessibilityNode(
                    role: "AXButton", title: "Don't Save",
                    frame: CGRect(x: 120, y: 200, width: 80, height: 24)),
                AccessibilityNode(
                    role: "AXButton", title: "Compose",
                    frame: CGRect(x: 10, y: 10, width: 30, height: 30)),
            ])
        let found = WalkthroughNavigator.dialogs(in: snapshot)
        #expect(found.count == 1)
        let text = WalkthroughNavigator.dialogText(found[0], in: snapshot)
        #expect(
            text.contains("Save changes?") && text.contains("Don't Save")
                && !text.contains("Compose"))
    }

    @Test("lost and from-here phrases re-plan; they win over start over")
    func replanCommand() {
        #expect(WalkthroughCommand.parse("I'm lost") == .replanHere)
        #expect(WalkthroughCommand.parse("that's not there") == .replanHere)
        #expect(WalkthroughCommand.parse("start again from here") == .replanHere)
        #expect(WalkthroughCommand.parse("start over") == .startOver)
    }

    @Test("a dialog step goes before the current one; a jump counts earlier steps done")
    func sessionMoves() {
        let steps = ["A", "B", "C", "D"].map {
            WalkthroughStep(kind: .click, instruction: "Click \($0).")
        }
        var session = WalkthroughSession(goal: "g", appName: nil, steps: steps)
        session.completeCurrentStep()
        session.insertStepBeforeCurrent(WalkthroughStep(kind: .click, instruction: "Click Cancel."))
        #expect(session.currentStep?.instruction == "Click Cancel.")
        session.completeCurrentStep()
        #expect(session.currentStep?.instruction == "Click B.")
        let afterJump = session.jump(to: 4)
        #expect(afterJump?.instruction == "Click D.")
        #expect(session.completedSteps.count == 4)
    }
}

@Suite("Step looks (D77)")
struct StepLookTests {
    let planned = WalkthroughStep(
        kind: .click, instruction: "Click the Departure field.",
        target: ElementQuery(role: .field, name: "Departure"), app: "Google Chrome",
        targetPointNorm1000: CGPoint(x: 400, y: 380), doneJSON: #"{"exists":"Done"}"#,
        shortcut: nil)

    @Test("go adapts the planned step and keeps what it doesn't mention")
    func go() {
        let reply =
            #"{"status":"go","instruction":"Click Departure, left of Return.","target":{"role":"button","name":"Departure","px":[380,402]}}"#
        guard case .go(let step) = WalkthroughPrompts.stepLook(in: reply, planned: planned) else {
            Issue.record("not go")
            return
        }
        #expect(step.instruction == "Click Departure, left of Return.")
        #expect(step.target == ElementQuery(role: .button, name: "Departure"))
        #expect(step.targetPointNorm1000 == CGPoint(x: 380, y: 402))
        #expect(step.app == "Google Chrome" && step.done == .exists("Done"))
    }

    @Test("choice, done and off-plan")
    func statuses() {
        let choice =
            #"{"status":"choice","instruction":"Now pick Sunday the 11th.","target":{"role":"button","name":"Sunday, October 11"},"done":{"text":"Sun, Oct 11"}}"#
        guard case .choice(let step) = WalkthroughPrompts.stepLook(in: choice, planned: planned)
        else {
            Issue.record("not choice")
            return
        }
        #expect(step.targetPointNorm1000 == nil)
        #expect(step.done == .text("Sun, Oct 11"))
        #expect(WalkthroughPrompts.stepLook(in: #"{"status":"done"}"#, planned: planned) == .done)
        let madeUp =
            #"{"status":"choice","instruction":"Pick Monday.","done":{"text-based":"Monday clicked"}}"#
        guard case .choice(let kept) = WalkthroughPrompts.stepLook(in: madeUp, planned: planned)
        else {
            Issue.record("not choice")
            return
        }
        #expect(kept.done == .exists("Done"))
        #expect(
            WalkthroughPrompts.stepLook(
                in: "```json\n{\"status\":\"off_plan\",\"reason\":\"a sign-in page\"}\n```",
                planned: planned) == .offPlan("a sign-in page"))
        #expect(WalkthroughPrompts.stepLook(in: "hmm", planned: planned) == nil)
    }

    @Test("the look prompt carries goal, progress, plan, controls and what was said")
    func prompt() {
        let prompt = WalkthroughPrompts.lookPrompt(
            goal: "book a flight",
            completed: [WalkthroughStep(kind: .click, instruction: "Open Flights.")],
            step: planned, nextStep: nil, controls: "button, Departure",
            whatHappened: "the step started",
            lastSaid: "Nice.")
        #expect(
            prompt.contains("Planned step: \"Click the Departure field.\" (field \"Departure\")"))
        #expect(prompt.contains("Done so far: \"Open Flights.\"."))
        #expect(prompt.contains("button, Departure") && prompt.contains("Last thing said"))
    }
}

@Suite("Walkthrough session (D74)")
struct WalkthroughSessionTests {
    func step(_ name: String) -> WalkthroughStep {
        WalkthroughStep(
            kind: .click, instruction: "Click \(name).",
            target: ElementQuery(role: .button, name: name))
    }

    @Test("the first planned step starts at once; later ones queue")
    func planning() {
        var session = WalkthroughSession(goal: "g", appName: nil)
        let first = session.appendPlannedStep(step("A"))
        let second = session.appendPlannedStep(step("B"))
        #expect(first && !second)
        #expect(session.progressText == "Step 1")
        session.planFinished()
        #expect(session.progressText == "Step 1 of 2")
    }

    @Test("complete, skip, back, start over")
    func progress() {
        var session = WalkthroughSession(
            goal: "g", appName: nil, steps: [step("A"), step("B"), step("C")])
        let afterComplete = session.completeCurrentStep()
        #expect(afterComplete == step("B"))
        let afterSkip = session.skipCurrentStep()
        #expect(afterSkip == step("C"))
        let afterBack = session.goBack()
        #expect(afterBack == step("B"))
        session.completeCurrentStep()
        let afterLast = session.completeCurrentStep()
        #expect(afterLast == nil)
        #expect(session.phase == .finished)
        #expect(session.completedSteps.count == 3)
        session.startOver()
        #expect(session.currentStep == step("A"))
    }

    @Test("a re-plan keeps finished steps and replaces the rest")
    func replan() {
        var session = WalkthroughSession(
            goal: "g", appName: nil, steps: [step("A"), step("B"), step("C")])
        session.completeCurrentStep()
        session.beginReplan()
        #expect(session.steps.count == 1)
        let startsNow = session.appendPlannedStep(step("B2"))
        #expect(startsNow)
        session.planFinished()
        #expect(session.currentStep == step("B2"))
    }

    @Test("the recap lists steps with shortcuts")
    func recap() {
        let text = WalkthroughSession.recapText(
            title: "Write a mail", appName: "Mail",
            steps: [WalkthroughStep(kind: .shortcut, instruction: "New message.", shortcut: "⌘N")])
        #expect(text.contains("1. New message.  [⌘N]"))
    }
}

@Suite("Walkthrough script lines")
struct WalkthroughScriptTests {
    func events(_ line: String) -> [ScriptEvent] {
        var parser = StreamingScriptParser()
        return parser.feed(line + "\n")
    }

    @Test("a plan step names its control, point and done predicate")
    func stepLine() {
        guard
            case .action(.step(let step)) = events(
                #"{"type":"step","step":2,"kind":"type","instruction":"Type a subject.","target":{"role":"field","name":"Subject","px":[400,120]},"label":"Subject field","done":{"value_not_empty":"Subject"},"done_when":"The Subject field has text.","shortcut":null}"#
            ).first
        else {
            Issue.record("no step")
            return
        }
        #expect(step.number == 2 && step.kind == .type)
        #expect(step.target == ElementQuery(role: .field, name: "Subject"))
        #expect(step.targetPointNorm1000 == CGPoint(x: 400, y: 120))
        #expect(step.done == .valueNotEmpty("Subject"))
        #expect(step.shortcut == nil)
    }

    @Test("keyboard steps don't hunt for a control; the step's app is kept (D76)")
    func keyboardSteps() {
        guard
            case .action(.step(let spotlight)) = events(
                #"{"type":"step","step":1,"kind":"shortcut","instruction":"Press Command Space.","label":"Spotlight search","app":"Finder","shortcut":"⌘Space"}"#
            ).first
        else {
            Issue.record("no step")
            return
        }
        #expect(!spotlight.hasTarget && !spotlight.needsVisibleControl)
        #expect(spotlight.app == "Finder")
        let dockClick = WalkthroughStep(
            kind: .click, instruction: "Click Chrome in the Dock.",
            target: ElementQuery(role: .button, name: "Google Chrome"), app: "Dock")
        #expect(dockClick.hasTarget && dockClick.needsVisibleControl)
    }

    @Test("Dock items count as buttons")
    func dockItems() {
        let dock = AccessibilitySnapshot(
            appName: "Dock", bundleIdentifier: "com.apple.dock", focusedWindowTitle: nil,
            documentURL: nil,
            nodes: [
                AccessibilityNode(
                    role: "AXDockItem", title: "Google Chrome",
                    frame: CGRect(x: 400, y: 900, width: 60, height: 60))
            ])
        #expect(
            AccessibilityMatcher.bestMatch(
                for: ElementQuery(role: .button, name: "Google Chrome"), in: dock, visibleArea: nil)
                != nil)
    }

    @Test("outline, verdict and goal lines still parse")
    func otherLines() {
        #expect(
            events(#"{"type":"outline","steps":["A","B"]}"#).first == .action(.outline(["A", "B"])))
        #expect(
            events(#"{"type":"verdict","step":4,"done":true}"#).first
                == .action(.verdict(WalkthroughVerdict(step: 4, done: true))))
        #expect(events(#"{"type":"goal_done"}"#).first == .action(.goalDone))
    }

    @Test("walkthrough turns drop prose instead of speaking it")
    func proseDropped() {
        var parser = StreamingScriptParser(speaksPlainText: false)
        #expect(
            parser.feed("I'll draw an ellipse.\n") == [
                .diagnostic(.plainTextDropped("I'll draw an ellipse."))
            ])
    }

    @Test("remember lines")
    func rememberLine() {
        #expect(
            events(
                #"{"type":"remember","fact":"New to grading","app":"DaVinci Resolve","skill":"beginner"}"#
            ).first
                == .action(
                    .remember(
                        RememberAction(
                            fact: "New to grading", app: "DaVinci Resolve", skill: "beginner"))))
    }

    @Test("saved how-tos still decode, and keep their done predicate")
    func savedSteps() throws {
        let old = #"{"kind":"menu","instruction":"Click File.","targetText":"File"}"#
        let decodedOld = try JSONDecoder().decode(WalkthroughStep.self, from: Data(old.utf8))
        #expect(decodedOld.instruction == "Click File.")
        let step = WalkthroughStep(
            kind: .click, instruction: "Click Compose.", doneJSON: #"{"window":"New Message"}"#)
        let roundTrip = try JSONDecoder().decode(
            WalkthroughStep.self, from: JSONEncoder().encode(step))
        #expect(roundTrip.done == .window("New Message"))
    }
}

@Suite("User memory and modes (§4.3)")
struct UserMemoryTests {
    @Test("facts dedupe and cap")
    func facts() {
        var memory = UserMemory()
        let added = memory.remember("Prefers short answers")
        let duplicateAdded = memory.remember("prefers short answers.")
        #expect(added)
        #expect(!duplicateAdded)
        for index in 0..<40 { memory.remember("fact \(index)") }
        #expect(memory.facts.count == UserMemory.maximumFactCount)
        #expect(memory.facts.last == "fact 39")
    }

    @Test("the prompt block lists facts and recent apps with skill")
    func promptBlock() {
        var memory = UserMemory()
        #expect(memory.promptBlock() == nil)
        let date = Date(timeIntervalSince1970: 1000)
        memory.recordQuestion(inApp: "Excel", at: date)
        memory.apply(
            RememberAction(
                fact: "New to colour grading", app: "DaVinci Resolve", skill: "Beginner"),
            at: date.addingTimeInterval(10))
        memory.recordWalkthroughCompleted(inApp: "DaVinci Resolve", at: date.addingTimeInterval(20))
        let block = memory.promptBlock() ?? ""
        #expect(block.contains("- New to colour grading"))
        #expect(block.contains("- DaVinci Resolve (beginner, 1 walkthroughs done)"))
        #expect(block.contains("- Excel"))
        #expect(block.count < UserMemory.maximumPromptCharacters + 200)
    }

    @Test("modes add their lines only when on")
    func modes() {
        #expect(AssistantModes(isStudyModeOn: false, isKidsModeOn: false).contextBlock == nil)
        let both = AssistantModes(isStudyModeOn: true, isKidsModeOn: true).contextBlock ?? ""
        #expect(both.contains("Study mode is on"))
        #expect(both.contains("Kids mode is on"))
    }

    @Test("region actions have distinct prompts; translate names the language")
    func regionActions() {
        #expect(RegionAction.translate.prompt(targetLanguage: "English").contains("into English"))
        #expect(RegionAction.summarise.prompt(targetLanguage: "English").contains("Summarise"))
        #expect(RegionAction.allCases.map(\.title) == ["Explain", "Summarise", "Translate"])
    }
}
