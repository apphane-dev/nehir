import Foundation

enum PureDirection: Equatable {
    case left
    case right
    case up
    case down

    var horizontalStep: Int? {
        switch self {
        case .left: -1
        case .right: 1
        case .up,
             .down: nil
        }
    }

    /// Storage-order step for vertical movement/focus.
    /// Storage index 0 is visual bottom, so visual up is +1 and visual down is -1.
    var verticalStorageStep: Int? {
        switch self {
        case .up: 1
        case .down: -1
        case .left,
             .right: nil
        }
    }
}
