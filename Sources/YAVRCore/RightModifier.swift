import IOKit.hidsystem

/// Device-specific bits preserve which side was down at the event's timestamp.
public enum RightModifier: String {
    case option = "rightOption", command = "rightCommand", control = "rightControl"
    public var keyCode: UInt16 {
        switch self { case .option: return 61; case .command: return 54; case .control: return 62 }
    }
    public func isPressed(flags: UInt64) -> Bool {
        let mask: Int32
        switch self {
        case .option: mask = NX_DEVICERALTKEYMASK
        case .command: mask = NX_DEVICERCMDKEYMASK
        case .control: mask = NX_DEVICERCTLKEYMASK
        }
        return flags & UInt64(mask) != 0
    }
}
