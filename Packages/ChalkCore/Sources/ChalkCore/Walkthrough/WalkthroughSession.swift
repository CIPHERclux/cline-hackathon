import Foundation

/// A guided walkthrough's goal, plan and progress (§4.2.6, D74). The model plans once; the app
/// runs the steps locally and only goes back to the model to re-plan when the screen no longer
/// fits the plan.
public struct WalkthroughSession: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The plan is still streaming in.
        case planning
        case running
        /// Re-planning from the current screen (the plan no longer fits it).
        case replanning
        case finished
        case stopped
    }

    /// §4.2.6 step 2: at most 25 steps.
    public static let maximumStepCount = 25

    public let goal: String
    public var appName: String?
    public private(set) var steps: [WalkthroughStep] = []
    public private(set) var currentIndex = 0
    public private(set) var skippedStepIndices: Set<Int> = []
    public private(set) var phase: Phase = .planning
    public private(set) var replanCount = 0

    public init(goal: String, appName: String?, steps: [WalkthroughStep] = []) {
        self.goal = goal
        self.appName = appName
        self.steps = Array(steps.prefix(Self.maximumStepCount))
        if !self.steps.isEmpty { phase = .running }
    }

    public var currentStep: WalkthroughStep? {
        steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
    }

    public var nextStep: WalkthroughStep? {
        steps.indices.contains(currentIndex + 1) ? steps[currentIndex + 1] : nil
    }

    public var isActive: Bool {
        switch phase {
        case .planning, .running, .replanning: return true
        case .finished, .stopped: return false
        }
    }

    public var stepNumber: Int { currentIndex + 1 }

    /// "Step 2 of 7"; while the plan streams, the total isn't known yet.
    public var progressText: String {
        phase == .planning || phase == .replanning
            ? "Step \(stepNumber)" : "Step \(stepNumber) of \(max(steps.count, stepNumber))"
    }

    public var completedSteps: [WalkthroughStep] {
        (0..<min(currentIndex, steps.count)).filter { !skippedStepIndices.contains($0) }
            .map { steps[$0] }
    }

    // MARK: Planning

    /// A planned step arrived. Returns true when it is the step to show now.
    @discardableResult
    public mutating func appendPlannedStep(_ step: WalkthroughStep) -> Bool {
        guard isActive, steps.count < Self.maximumStepCount else { return false }
        steps.append(step)
        return steps.count == currentIndex + 1
    }

    public mutating func planFinished() {
        guard phase == .planning || phase == .replanning else { return }
        phase = steps.indices.contains(currentIndex) ? .running : .finished
    }

    /// Keep what's done, replace everything from the current step.
    public mutating func beginReplan() {
        steps.removeSubrange(min(currentIndex, steps.count)...)
        skippedStepIndices = skippedStepIndices.filter { $0 < currentIndex }
        replanCount += 1
        phase = .replanning
    }

    /// Adaptive mode retains completed actions without inventing a total or exhausting replans.
    public mutating func awaitNextAdaptiveStep() {
        guard phase != .stopped else { return }
        steps.removeSubrange(min(currentIndex, steps.count)...)
        skippedStepIndices = skippedStepIndices.filter { $0 < currentIndex }
        phase = .planning
    }

    // MARK: Progress

    /// The current step is done. Returns the next step, or nil (finished, or still streaming).
    @discardableResult
    public mutating func completeCurrentStep() -> WalkthroughStep? {
        guard currentStep != nil else { return nil }
        return moveForward()
    }

    /// A live look adapted the current step to the screen (D77).
    public mutating func replaceCurrentStep(_ step: WalkthroughStep) {
        guard steps.indices.contains(currentIndex) else { return }
        steps[currentIndex] = step
    }

    /// A step that deals with something unexpected (a dialog) goes before the current one; the
    /// current step follows once it's done (D75).
    public mutating func insertStepBeforeCurrent(_ step: WalkthroughStep) {
        guard isActive, steps.count < Self.maximumStepCount else { return }
        steps.insert(step, at: min(currentIndex, steps.count))
        skippedStepIndices = Set(skippedStepIndices.map { $0 >= currentIndex ? $0 + 1 : $0 })
    }

    /// The user did steps ahead (D75): everything before `index` counts as done.
    @discardableResult
    public mutating func jump(to index: Int) -> WalkthroughStep? {
        guard index > currentIndex else { return currentStep }
        currentIndex = min(index, steps.count)
        if currentStep == nil, phase == .running { phase = .finished }
        return currentStep
    }

    @discardableResult
    public mutating func skipCurrentStep() -> WalkthroughStep? {
        guard currentStep != nil else { return nil }
        skippedStepIndices.insert(currentIndex)
        return moveForward()
    }

    @discardableResult
    public mutating func goBack() -> WalkthroughStep? {
        guard currentIndex > 0 else { return currentStep }
        currentIndex -= 1
        skippedStepIndices.remove(currentIndex)
        if phase == .finished { phase = .running }
        return currentStep
    }

    public mutating func startOver() {
        currentIndex = 0
        skippedStepIndices.removeAll()
        if !steps.isEmpty { phase = .running }
    }

    public mutating func stop() {
        phase = .stopped
    }

    public mutating func finish() {
        currentIndex = steps.count
        phase = .finished
    }

    private mutating func moveForward() -> WalkthroughStep? {
        currentIndex += 1
        if let next = currentStep { return next }
        if phase == .running { phase = .finished }
        return nil
    }

    // MARK: Recap (§4.2.6 step 9)

    public var title: String {
        let cleaned = WalkthroughIntent.taskTitle(from: goal)
        return cleaned.count > 60 ? String(cleaned.prefix(57)) + "…" : cleaned
    }

    /// Plain text, copyable (§4.2.6 step 9).
    public static func recapText(title: String, appName: String?, steps: [WalkthroughStep])
        -> String
    {
        var lines = [appName.map { "\(title) (\($0))" } ?? title, ""]
        for (index, step) in steps.enumerated() {
            let shortcut =
                step.shortcut.flatMap(KeyboardShortcut.init(parsing:))?.symbols ?? step.shortcut
            lines.append("\(index + 1). \(step.instruction)\(shortcut.map { "  [\($0)]" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}
