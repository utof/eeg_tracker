package io.github.utof.eeg_tracker

import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent

/**
 * Android binds this while the paired headband is in Bluetooth LE range (presence observing, AutoWatch.kt): the
 * binding keeps the app's process ready and allows the check to start from the background. Only "came near" and
 * "went" count; Bluetooth connect and disconnect are ignored, since the app's own connections make those.
 * Android 12: the String callbacks; 13-15: the AssociationInfo ones; 16+: presence events.
 */
class HeadbandPresenceService : CompanionDeviceService() {
    @Deprecated("Android 12 only")
    override fun onDeviceAppeared(address: String) = AutoWatch.onPresence(this, true)

    @Deprecated("Android 12 only")
    override fun onDeviceDisappeared(address: String) = AutoWatch.onPresence(this, false)

    override fun onDeviceAppeared(associationInfo: AssociationInfo) = AutoWatch.onPresence(this, true)

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) = AutoWatch.onPresence(this, false)

    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        when (event.event) {
            DevicePresenceEvent.EVENT_BLE_APPEARED -> AutoWatch.onPresence(this, true)
            DevicePresenceEvent.EVENT_BLE_DISAPPEARED -> AutoWatch.onPresence(this, false)
        }
    }
}
