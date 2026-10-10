import CoreGraphics
import Foundation

/// Whether a step predicted ahead of time fits the screen that is really there (D86). Strong:
/// show it now, no model call. Medium: plausible, so the checker confirms it while the planner
/// runs. Reject: plan instead.
public enum GuideCandidateVerdict: Equatable, Sendable {
    case strong
    case medium
    case reject(String)
}

public enum GuideCandidateAssessor {
    public static func assess(_ candidate: GuideCandidate, on observation: GuideObservation)
        -> GuideCandidateVerdict
    {
        let step = candidate.step
        if let app = step.app, app.lowercased() != "dock",
            !GuideCandidateAssessor.sameApp(app, observation.appName)
        {
            return .reject("different app")
        }
        var ceiling = GuideCandidateVerdict.strong
        if let precondition = candidate.precondition {
            switch observation.evaluate(precondition) {
            case false?: return .reject("precondition false")
            case nil: ceiling = .medium
            case true?: break
            }
        }
        // Its check already holds: it can't tell this step apart, so only the checker can
        // confirm the prediction.
        if observation.evaluate(step.done) == true { ceiling = .medium }
        guard step.needsVisibleControl || (step.kind == .type && step.target != nil) else {
            // A shortcut or an observation: nothing to find.
            return step.kind == .observe ? .medium : ceiling
        }
        guard let target = step.target else { return .reject("no control named") }
        if let snapshot = observation.snapshot, snapshot.isUsable {
            if let node = AccessibilityMatcher.bestMatch(
                for: target, in: snapshot, visibleArea: nil)
            {
                let rank =
                    node.names.compactMap {
                        FuzzyTextMatch.rank(candidate: $0, wanted: target.name)
                    }
                    .min() ?? 9
                guard node.isEnabled else { return .reject("control disabled") }
                return rank <= 1 ? ceiling : .medium
            }
        }
        let textHit = observation.visibleTexts.contains {
            (FuzzyTextMatch.rank(candidate: $0.text, wanted: target.name) ?? 9) <= 1
        }
        return textHit ? .medium : .reject("control not on screen")
    }

    static func sameApp(_ wanted: String, _ actual: String?) -> Bool {
        guard let actual, !actual.isEmpty else { return false }
        return actual.localizedCaseInsensitiveContains(wanted)
            || wanted.localizedCaseInsensitiveContains(actual)
    }
}
