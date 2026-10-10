import Foundation
import Testing

@testable import ChalkCore

@Suite("Model router (§7.4)")
struct ModelRouterTests {
    @Test(
        "router rules table",
        arguments: [
            ("how do I export this design?", false, ModelSlot.teaching),
            ("can you draw how this formula works", false, .deep),
            ("prove that this converges", false, .deep),
            ("go deeper on that", true, .deep),
            ("why?", true, .fast),
            ("and what about the second one", true, .fast),
            ("why?", false, .teaching),
            (
                "ok so can you explain the whole layers panel and what each of these icons does",
                true, .teaching
            ),
            ("what's this graph showing", false, .deep),
            ("the graphics card", false, .teaching),
        ])
    func routerRules(transcript: String, isFollowUp: Bool, expectedSlot: ModelSlot) {
        #expect(ModelRouter.slot(forTranscript: transcript, isFollowUp: isFollowUp) == expectedSlot)
    }

    let configuration = try! JSONDecoder().decode(
        ModelRoutingConfiguration.self,
        from: Data(
            #"""
            {"defaultProfile": "demo", "profiles": {
              "demo": {"providerId": "cline",
                "slots": {"fast": {"primary": "text/only-model", "fallbacks": ["vision/model-a"]},
                          "teaching": {"primary": "vision/model-b", "fallbacks": []},
                          "deep": {"primary": "text/only-model", "fallbacks": []}},
                "vision": ["vision/model-a", "vision/model-b"]}}}
            """#.utf8))

    @Test("image turns skip models that cannot see (P-NOVISION)")
    func visionGuardSkipsTextOnlyModels() throws {
        let router = ModelRouter(configuration: configuration)
        #expect(try router.candidateModels(for: .fast, requiresVision: true) == ["vision/model-a"])
        #expect(
            try router.candidateModels(for: .fast, requiresVision: false) == [
                "text/only-model", "vision/model-a",
            ])
    }

    @Test("an image turn is refused when no model in the slot can see")
    func visionGuardRefuses() {
        let router = ModelRouter(configuration: configuration)
        #expect(throws: ModelRouter.RoutingError.noVisionModel(.deep)) {
            try router.candidateModels(for: .deep, requiresVision: true)
        }
    }

    @Test("the real model-routing.json loads, and every demo image slot has a vision model")
    func realConfigurationIsUsable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = try ModelRoutingConfiguration.load(
            from: repositoryRoot.appendingPathComponent("Sidecar/model-routing.json"))
        for profileName in ["demo", "dev"] {
            let router = ModelRouter(configuration: configuration, profileName: profileName)
            for slot in [ModelSlot.fast, .teaching, .deep] {
                #expect(
                    try !router.candidateModels(for: slot, requiresVision: true).isEmpty,
                    "\(profileName) \(slot)")
            }
        }
    }
}
