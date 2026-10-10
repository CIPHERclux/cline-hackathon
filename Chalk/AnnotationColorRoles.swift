//
//  AnnotationColorRoles.swift
//  Chalk
//
//  §5.6 color semantics remain stable; presentation comes from the Chalk palette.
//

import AppKit
import SwiftUI

enum AnnotationColorRole: String {
    case focus, explain, correct, mistake, learner, neutral

    init(scriptRole: String?) {
        self = AnnotationColorRole(rawValue: scriptRole ?? "") ?? .focus
    }

    var color: NSColor {
        switch self {
        case .focus:
            return NSColor(DS.Colors.overlayBeacon)
        case .explain:
            return NSColor(DS.Colors.explainInk)
        case .correct:
            return NSColor(DS.Colors.correctInk)
        case .mistake:
            return NSColor(DS.Colors.mistakeInk)
        case .learner:
            return NSColor(DS.Colors.learnerInk)
        case .neutral: return NSColor(DS.Colors.paper)
        }
    }
}
