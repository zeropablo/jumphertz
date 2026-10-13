import Foundation

public protocol Cancellable: AnyObject {
    func cancel()
}

/// Delayed execution on the controller's thread, injectable so that timing logic can be unit tested.
public protocol Scheduler: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> Cancellable
}

/// Production scheduler: the main queue (where the controller, NSWorkspace and HAL listeners all run).
public final class MainQueueScheduler: Scheduler {
    private final class Item: Cancellable {
        let work: DispatchWorkItem
        init(_ work: DispatchWorkItem) { self.work = work }
        func cancel() { work.cancel() }
    }

    public init() {}

    public var now: Date { Date() }

    @discardableResult
    public func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> Cancellable {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return Item(work)
    }
}
