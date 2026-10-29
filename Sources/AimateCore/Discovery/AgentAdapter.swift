import Foundation

/// A pull-mode integrator: it observes something an agent already leaves behind
/// and converts it into actors. Adapters need no per-session setup, which is the
/// whole point — a new Qoder conversation shows up without the user telling us.
public protocol AgentAdapter: AnyObject {
    var source: String { get }
    func poll(now: Date) -> [Actor]
}
