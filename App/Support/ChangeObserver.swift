import Foundation
import Observation

/// 监听 @Observable 对象中某个值的变化（基于 withObservationTracking）
@MainActor
enum ChangeObserver {
    static func observe<Value: Equatable>(
        _ value: @escaping @MainActor () -> Value,
        initial: Bool = true,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        var last = value()
        if initial { onChange(last) }

        func track() {
            withObservationTracking {
                _ = value()
            } onChange: {
                Task { @MainActor in
                    let current = value()
                    if current != last {
                        last = current
                        onChange(current)
                    }
                    track()
                }
            }
        }
        track()
    }
}
