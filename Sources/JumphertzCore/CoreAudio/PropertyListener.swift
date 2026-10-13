import CoreAudio
import Foundation

/// A HAL property listener delivered on the main queue, removed by `remove()` or on deinit.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ handler: @escaping () -> Void) {
        self.object = object
        address = HAL.address(selector, scope)
        block = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else {
            Log.audio.error("Cannot listen to '\(HAL.fourCC(selector), privacy: .public)' on \(object): \(status)")
            return nil
        }
        installed = true
    }

    /// Must be called on the main queue (the listener queue): removal then cannot race a running callback.
    func remove() {
        guard installed else { return }
        installed = false
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit { remove() }
}
