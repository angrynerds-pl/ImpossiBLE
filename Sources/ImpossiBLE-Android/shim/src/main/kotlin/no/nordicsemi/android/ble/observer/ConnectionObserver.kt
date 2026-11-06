package no.nordicsemi.android.ble.observer

import com.impossible.ble.BleDevice

interface ConnectionObserver {
    fun onDeviceConnecting(device: BleDevice)

    fun onDeviceConnected(device: BleDevice)

    fun onDeviceFailedToConnect(device: BleDevice, reason: Int)

    fun onDeviceReady(device: BleDevice)

    fun onDeviceDisconnecting(device: BleDevice)

    fun onDeviceDisconnected(device: BleDevice, reason: Int)

    companion object {
        const val REASON_UNKNOWN = -1
        const val REASON_SUCCESS = 0
        const val REASON_TERMINATE_LOCAL_HOST = 1
        const val REASON_TERMINATE_PEER_USER = 2
        const val REASON_LINK_LOSS = 3
        const val REASON_NOT_SUPPORTED = 4
        const val REASON_CANCELLED = 5
        const val REASON_TIMEOUT = 10
    }
}
