import Foundation

enum MatchingConfidence: Int, Comparable, CustomStringConvertible {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    static func < (lhs: MatchingConfidence, rhs: MatchingConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .none:
            return "none"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        }
    }
}

struct AXWindowMatch {
    let window: AXWindowSnapshot
    let score: Int
    let confidence: MatchingConfidence
    let explanations: [String]

    var debugSummary: String {
        "score=\(score), confidence=\(confidence), explanations=\(explanations.joined(separator: " | ")), window={\(window.debugSummary)}"
    }
}

struct CGWindowGeometryMatch {
    let candidate: CGWindowCandidate
    let score: Int
    let confidence: MatchingConfidence
    let predictedBounds: CGRect?
    let explanations: [String]

    var debugSummary: String {
        let predictedText = predictedBounds.map { "\($0.integral)" } ?? "nil"
        return "score=\(score), confidence=\(confidence), predictedBounds=\(predictedText), explanations=\(explanations.joined(separator: " | ")), candidate={\(candidate.debugSummary)}"
    }
}

