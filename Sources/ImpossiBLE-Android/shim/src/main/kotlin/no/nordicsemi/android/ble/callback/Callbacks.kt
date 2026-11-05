package no.nordicsemi.android.ble.callback

import com.impossible.ble.BleDevice
import no.nordicsemi.android.ble.data.Data

fun interface DataReceivedCallback {
    fun onDataReceived(device: BleDevice, data: Data)
}

fun interface DataSentCallback {
    fun onDataSent(device: BleDevice, data: Data)
}

fun interface SuccessCallback {
    fun onRequestCompleted(device: BleDevice)
}

fun interface AfterCallback {
    fun onRequestFinished(device: BleDevice)
}

fun interface InvalidRequestCallback {
    fun onInvalidRequest()
}

fun interface FailCallback {
    fun onRequestFailed(device: BleDevice, status: Int)

    companion object {
        const val REASON_DEVICE_DISCONNECTED = -1
        const val REASON_DEVICE_NOT_SUPPORTED = -2
        const val REASON_NULL_ATTRIBUTE = -3
        const val REASON_REQUEST_FAILED = -4
        const val REASON_TIMEOUT = -5
        const val REASON_VALIDATION = -6
        const val REASON_CANCELLED = -7
        const val REASON_BLUETOOTH_DISABLED = -100
    }
}
