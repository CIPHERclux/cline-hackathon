import Testing

@testable import ChalkCore

/// The §6.4 scenario S1 example, one NDJSON line per action, exactly as the spec shows it.
let specificationExampleScript = #"""
    {"v": 1, "type": "meta", "mode": "explain", "lang": "en"}
    {"type": "speak", "group": "g1", "text": "Good eye. Swapping {a1}this sum and {a2}this integral isn't automatic."}
    {"type": "draw", "shape": "ellipse", "target": {"mark": 41}, "at": "a1", "role": "focus", "id": "s1", "group": "g1"}
    {"type": "draw", "shape": "ellipse", "target": {"text": "∫", "near": {"mark": 41}}, "at": "a2", "role": "focus", "id": "s2", "group": "g1"}
    {"type": "draw", "shape": "curved_arrow", "from": {"mark": 41}, "to": {"text": "∫", "near": {"mark": 41}}, "at": "a2", "role": "explain", "id": "s3", "group": "g1"}
    {"type": "speak", "group": "g2", "text": "It works here because the series converges {a3}uniformly on the interval."}
    {"type": "draw", "shape": "label", "target": {"relative": {"of": {"mark": 41}, "pos": "right", "gap": 24}}, "label": "needs uniform convergence", "at": "a3", "role": "explain", "id": "s4", "group": "g2"}
    {"type": "check", "kind": "free", "question": "What could go wrong if it only converged pointwise?", "answer_key": "limit and integral may differ; e.g. f_n = n·1[0,1/n]"}
    {"type": "wait_for_user", "prompt_id": "q1", "timeout_s": 30}
    {"type": "end"}

    """#

func parseAll(_ deltas: [String]) -> [ScriptEvent] {
    var parser = StreamingScriptParser()
    var events: [ScriptEvent] = []
    for delta in deltas { events += parser.feed(delta) }
    return events + parser.finish()
}

func actions(_ events: [ScriptEvent]) -> [ScriptAction] {
    events.compactMap { event in
        if case .action(let action) = event { return action }
        return nil
    }
}

func diagnostics(_ events: [ScriptEvent]) -> [ScriptDiagnostic] {
    events.compactMap { event in
        if case .diagnostic(let diagnostic) = event { return diagnostic }
        return nil
    }
}

@Suite("Streaming parser (§6.4)")
struct StreamingScriptParserTests {
    @Test("the spec example parses into the 10 expected actions, with no diagnostics")
    func specificationExampleParses() throws {
        let events = parseAll([specificationExampleScript])
        #expect(diagnostics(events).isEmpty)
        let parsed = actions(events)
        #expect(parsed.count == 10)
        #expect(parsed.first == .meta(MetaAction(version: 1, mode: "explain", language: "en")))
        #expect(parsed.last == .end)
        guard case .draw(let curvedArrow) = parsed[4] else {
            Issue.record("expected draw")
            return
        }
        #expect(curvedArrow.shape == .curvedArrow)
        #expect(curvedArrow.from == .mark(id: 41))
        #expect(curvedArrow.to == .text("∫", near: .mark(id: 41), within: nil))
        guard case .draw(let label) = parsed[6] else {
            Issue.record("expected draw")
            return
        }
        #expect(label.target == .relative(of: .mark(id: 41), position: .right, gap: 24))
        guard case .check(let check) = parsed[7] else {
            Issue.record("expected check")
            return
        }
        #expect(check.answerKey?.hasPrefix("limit and integral") == true)
    }

    @Test("split at every character boundary, the example yields identical actions")
    func splitAtEveryBoundaryIsIdentical() {
        let expected = parseAll([specificationExampleScript])
        // Deltas are Strings (the sidecar forwards JS strings), so the finest split is per Unicode
        // scalar; that includes splits inside the multi-byte "∫" and "·" lines' neighbours.
        let scalars = Array(specificationExampleScript.unicodeScalars)
        for splitIndex in 0...scalars.count {
            var head = String.UnicodeScalarView()
            head.append(contentsOf: scalars[..<splitIndex])
            var tail = String.UnicodeScalarView()
            tail.append(contentsOf: scalars[splitIndex...])
            #expect(
                parseAll([String(head), String(tail)]) == expected, "split at scalar \(splitIndex)")
        }
    }

    @Test("one scalar per delta yields identical actions")
    func scalarByScalarIsIdentical() {
        let deltas = specificationExampleScript.unicodeScalars.map { String($0) }
        #expect(parseAll(deltas) == parseAll([specificationExampleScript]))
    }

    @Test("plain text interleaved between lines becomes speak")
    func plainTextBecomesSpeech() {
        let events = parseAll([
            "Sure, let me show you.\n", #"{"type":"point","target":{"mark":3}}"#, "\n",
            "That's the export button.\n",
        ])
        #expect(
            actions(events) == [
                .speak(SpeakAction(text: "Sure, let me show you.")),
                .point(PointAction(target: .mark(id: 3), anchor: nil, label: nil, identifier: nil)),
                .speak(SpeakAction(text: "That's the export button.")),
            ])
    }

    @Test("an unknown type is dropped and reported")
    func unknownTypeDropped() {
        let events = parseAll([
            #"{"type":"dance","target":{"mark":1}}"# + "\n" + #"{"type":"end"}"# + "\n"
        ])
        #expect(actions(events) == [.end])
        #expect(diagnostics(events) == [.unknownType("dance")])
    }

    @Test("non-demo primitives are dropped, never drawn (D01)")
    func nonDemoPrimitivesDropped() {
        let script =
            [
                #"{"type":"draw","shape":"spotlight","target":{"mark":1}}"#,
                #"{"type":"draw","shape":"bracket","target":{"mark":2}}"#,
                #"{"type":"draw","shape":"freehand","target":{"mark":3}}"#,
                #"{"type":"draw","shape":"ring","target":{"mark":4}}"#,
                #"{"type":"figure","kind":"plot","spec":{"domain":[0,1]}}"#,
            ].joined(separator: "\n") + "\n"
        let events = parseAll([script])
        #expect(actions(events).count == 1)
        #expect(
            diagnostics(events) == [
                .outOfDemoScope("draw:spotlight"), .outOfDemoScope("draw:bracket"),
                .outOfDemoScope("draw:freehand"),
                .outOfDemoScope("figure:plot"),
            ])
    }

    @Test("demo figures are accepted: numberline and math_steps (D02)")
    func demoFiguresAccepted() {
        let script =
            [
                #"{"type":"figure","kind":"numberline","spec":{"range":[-2,2]},"surface":"board","id":"f1"}"#,
                #"{"type":"figure","kind":"math_steps","spec":{"lines":["x+1=2","x=1"]}}"#,
            ].joined(separator: "\n") + "\n"
        let kinds = actions(parseAll([script])).compactMap { action -> FigureKind? in
            if case .figure(let figure) = action { return figure.kind }
            return nil
        }
        #expect(kinds == [.numberline, .mathSteps])
    }

    @Test("cite is out of demo scope and dropped")
    func citeDropped() {
        let events = parseAll([
            #"{"type":"cite","doc":"notes.pdf","page":3,"quote":"uniform"}"# + "\n"
        ])
        #expect(actions(events).isEmpty)
        #expect(diagnostics(events) == [.outOfDemoScope("cite")])
    }

    @Test("2 KB without a newline is spoken as plain text")
    func overlongLineFlushedAsSpeech() {
        let longSentence = String(repeating: "This keeps going without a line break. ", count: 60)
        var parser = StreamingScriptParser()
        var events: [ScriptEvent] = []
        for chunk in stride(from: 0, to: longSentence.count, by: 100) {
            let start = longSentence.index(longSentence.startIndex, offsetBy: chunk)
            let end = longSentence.index(start, offsetBy: min(100, longSentence.count - chunk))
            events += parser.feed(String(longSentence[start..<end]))
        }
        #expect(
            diagnostics(events).contains {
                if case .overlongLineSpokenAsText = $0 { true } else { false }
            })
        guard case .speak(let speech) = actions(events).first else {
            Issue.record("expected speech")
            return
        }
        #expect(
            speech.text.utf8.count > StreamingScriptParser.maximumBufferedBytesWithoutNewline - 100)
        // Nothing is spoken twice: the rest of the line continues from where the flush stopped.
        let remainder = actions(events + parser.finish()).compactMap { action -> String? in
            if case .speak(let speak) = action { return speak.text }
            return nil
        }.joined(separator: " ")
        #expect(remainder.count <= longSentence.count)
    }

    @Test("code fences around the script are stripped")
    func codeFencesRepaired() {
        let events = parseAll([
            "```json\n", #"{"type":"speak","text":"Hi"}"#, "\n", #"{"type":"end"}"#, "\n```\n",
        ])
        #expect(actions(events) == [.speak(SpeakAction(text: "Hi")), .end])
        #expect(diagnostics(events).allSatisfy { $0 == .repaired(.codeFence) })
    }

    @Test("a fence glued to a line is stripped too")
    func gluedCodeFenceRepaired() {
        let events = parseAll([#"```json {"type":"end"}```"# + "\n"])
        #expect(actions(events) == [.end])
    }

    @Test("trailing commas are repaired, including the array-style comma after an object")
    func trailingCommasRepaired() {
        let script =
            [
                "[",
                #"{"type":"speak","text":"One, two,","group":"g1",},"#,
                #"{"type":"clear","ids":["s1","s2",],}"#,
                "]",
            ].joined(separator: "\n") + "\n"
        let events = parseAll([script])
        #expect(
            actions(events) == [
                .speak(SpeakAction(text: "One, two,", group: "g1")),
                .clear(ClearAction(scope: .identifiers(["s1", "s2"]), fadeMilliseconds: nil)),
            ])
        #expect(diagnostics(events).filter { $0 == .repaired(.trailingComma) }.count == 2)
    }

    @Test("broken JSON is dropped and counted, not read aloud")
    func malformedJSONDropped() {
        var parser = StreamingScriptParser()
        let events = parser.feed(
            #"{"type":"speak","text":"unterminated}"# + "\n" + #"{"type":"end"}"# + "\n")
        #expect(actions(events) == [.end])
        #expect(parser.statistics.jsonLines == 2)
        #expect(parser.statistics.malformedJSONLines == 1)
        #expect(parser.statistics.malformedRate == 0.5)
    }

    @Test("a final line without a newline is processed on finish")
    func finishFlushesLastLine() {
        var parser = StreamingScriptParser()
        #expect(parser.feed(#"{"type":"end"}"#).isEmpty)
        #expect(actions(parser.finish()) == [.end])
    }

    @Test("CRLF line endings and blank lines are handled")
    func carriageReturnsAndBlankLines() {
        let events = parseAll([
            "{\"type\":\"speak\",\"text\":\"Hi\"}\r\n\r\n\n{\"type\":\"end\"}\r\n"
        ])
        #expect(actions(events) == [.speak(SpeakAction(text: "Hi")), .end])
        #expect(diagnostics(events).isEmpty)
    }
}

@Suite("Validator (§6.4 recovery, §6.2 targets)")
struct ScriptValidatorTests {
    @Test("draw or point without a usable target becomes speech-only with a low-confidence event")
    func missingTargetDowngraded() {
        let events = parseAll([
            #"{"type":"draw","shape":"ellipse","at":"a1"}"# + "\n"
                + #"{"type":"point","target":{"nonsense":1}}"# + "\n"
        ])
        #expect(actions(events).isEmpty)
        #expect(
            diagnostics(events) == [
                .downgradedToSpeechOnly(type: "draw:ellipse", reason: "missing or unusable target"),
                .downgradedToSpeechOnly(type: "point", reason: "missing or unusable target"),
            ])
    }

    @Test("raw pixel targets are kept but flagged low-confidence")
    func pixelTargetFlagged() {
        let events = parseAll([
            #"{"type":"point","target":{"px":[1180,212],"space":"image"}}"# + "\n"
        ])
        #expect(
            actions(events) == [
                .point(
                    PointAction(
                        target: .pixel(x: 1180, y: 212, space: "image"), anchor: nil, label: nil,
                        identifier: nil))
            ])
        #expect(diagnostics(events) == [.lowConfidenceTarget(type: "point")])
    }

    @Test("all five descriptor shapes parse")
    func descriptorShapes() {
        #expect(TargetDescriptor(json: JSONValue.parse(#"{"mark":17}"#)!) == .mark(id: 17))
        #expect(
            TargetDescriptor(
                json: JSONValue.parse(
                    #"{"text":"Auto layout","near":{"mark":12},"within":"window:frontmost"}"#)!)
                == .text("Auto layout", near: .mark(id: 12), within: "window:frontmost"))
        #expect(
            TargetDescriptor(
                json: JSONValue.parse(
                    #"{"region":{"x":0.62,"y":0.1,"w":0.3,"h":0.25},"space":"window:frontmost"}"#)!)
                == .region(
                    NormalizedRect(x: 0.62, y: 0.1, width: 0.3, height: 0.25),
                    space: "window:frontmost"))
        #expect(
            TargetDescriptor(
                json: JSONValue.parse(#"{"relative":{"of":{"mark":17},"pos":"below","gap":8}}"#)!)
                == .relative(of: .mark(id: 17), position: .below, gap: 8))
        #expect(
            TargetDescriptor(json: JSONValue.parse(#"{"px":[1180,212],"space":"image"}"#)!)
                == .pixel(x: 1180, y: 212, space: "image"))
        #expect(TargetDescriptor(json: JSONValue.parse(#"{"mark":"seventeen"}"#)!) == nil)
    }

    @Test("clear accepts ids or all")
    func clearScopes() {
        let events = parseAll([
            #"{"type":"clear","ids":"all","fade_ms":200}"# + "\n"
                + #"{"type":"clear","ids":["s1"]}"# + "\n"
        ])
        #expect(
            actions(events) == [
                .clear(ClearAction(scope: .all, fadeMilliseconds: 200)),
                .clear(ClearAction(scope: .identifiers(["s1"]), fadeMilliseconds: nil)),
            ])
    }

    @Test("a newer script version is reported but still parsed")
    func unsupportedVersionReported() {
        let events = parseAll([#"{"v":2,"type":"meta","mode":"explain"}"# + "\n"])
        #expect(diagnostics(events) == [.unsupportedVersion(2)])
        #expect(actions(events) == [.meta(MetaAction(version: 2, mode: "explain", language: nil))])
    }

    @Test("a choice check needs choices")
    func choiceCheckNeedsChoices() {
        let events = parseAll([
            #"{"type":"check","kind":"choice","question":"Which?","choices":["A"]}"# + "\n"
        ])
        #expect(actions(events).isEmpty)
    }

    @Test("trailing-comma repair leaves commas inside strings alone")
    func trailingCommaRepairRespectsStrings() {
        #expect(
            StreamingScriptParser.removingTrailingCommas(#"{"text":"a, }",}"#)
                == #"{"text":"a, }"}"#)
        #expect(
            StreamingScriptParser.removingTrailingCommas(#"{"t":"q\",}",}"#) == #"{"t":"q\",}"}"#)
    }
}
