/// What a probe saw when it looked for an effect.
public enum ProbeReading<Output: Sendable>: Sendable {
    /// The effect is visible, and this is what it produced.
    case applied(Output)
    /// The effect is not visible. Until the visibility window has passed, that does not prove it
    /// did not happen: many stores show a write to readers some time after acknowledging it.
    case absent
}
