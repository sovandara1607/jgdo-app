
import Foundation

enum WindowLayout: String, CaseIterable {
    case leftHalf    = "Left Half"
    case rightHalf   = "Right Half"
    case topHalf     = "Top Half"
    case bottomHalf  = "Bottom Half"
    case topLeft     = "Top Left"
    case topRight    = "Top Right"
    case bottomLeft  = "Bottom Left"
    case bottomRight = "Bottom Right"
    case maximize    = "Maximize"
    case center      = "Center"

    var icon: String {
        switch self {
        case .leftHalf:    return "rectangle.lefthalf.inset.filled"
        case .rightHalf:   return "rectangle.righthalf.inset.filled"
        case .topHalf:     return "rectangle.tophalf.inset.filled"
        case .bottomHalf:  return "rectangle.bottomhalf.inset.filled"
        case .topLeft:     return "rectangle.inset.topleft.filled"
        case .topRight:    return "rectangle.inset.topright.filled"
        case .bottomLeft:  return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .maximize:    return "rectangle.inset.filled"
        case .center:      return "rectangle.center.inset.filled"
        }
    }

    /// The complementary layout placed on the previous app when a paired resize fires.
    var complement: WindowLayout? {
        switch self {
        case .leftHalf:    return .rightHalf
        case .rightHalf:   return .leftHalf
        case .topHalf:     return .bottomHalf
        case .bottomHalf:  return .topHalf
        case .topLeft:     return .bottomRight
        case .topRight:    return .bottomLeft
        case .bottomLeft:  return .topRight
        case .bottomRight: return .topLeft
        default:           return nil
        }
    }
}
