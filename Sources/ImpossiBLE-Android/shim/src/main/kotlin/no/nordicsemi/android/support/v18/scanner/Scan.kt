package no.nordicsemi.android.support.v18.scanner

import android.os.ParcelUuid
import com.impossible.ble.BleDevice

class ScanSettings private constructor(val reportDelayMillis: Long, val scanMode: Int) {
    class Builder {
        private var reportDelay = 0L
        private var mode = SCAN_MODE_LOW_POWER

        fun setLegacy(legacy: Boolean) = this

        fun setScanMode(scanMode: Int) = apply { mode = scanMode }

        fun setReportDelay(millis: Long) = apply { reportDelay = millis }

        fun setUseHardwareBatchingIfSupported(enabled: Boolean) = this

        fun setCallbackType(callbackType: Int) = this

        fun build() = ScanSettings(reportDelay, mode)
    }

    companion object {
        const val SCAN_MODE_OPPORTUNISTIC = -1
        const val SCAN_MODE_LOW_POWER = 0
        const val SCAN_MODE_BALANCED = 1
        const val SCAN_MODE_LOW_LATENCY = 2
        const val CALLBACK_TYPE_ALL_MATCHES = 1
    }
}

class ScanFilter private constructor(val deviceName: String?, val serviceUuid: ParcelUuid?) {
    class Builder {
        private var name: String? = null
        private var uuid: ParcelUuid? = null

        fun setDeviceName(deviceName: String?) = apply { name = deviceName }

        fun setServiceUuid(serviceUuid: ParcelUuid?) = apply { uuid = serviceUuid }

        fun build() = ScanFilter(name, uuid)
    }
}

class ScanRecord(val deviceName: String?, private val serviceUuidStrings: List<String>) {
    val serviceUuids: List<ParcelUuid> by lazy { serviceUuidStrings.map(ParcelUuid::fromString) }

    val bytes: ByteArray? = null
}

class ScanResult(val device: BleDevice, val rssi: Int, val scanRecord: ScanRecord?, val timestampNanos: Long)

open class ScanCallback {
    open fun onScanResult(callbackType: Int, result: ScanResult) = Unit

    open fun onBatchScanResults(results: MutableList<ScanResult>) = Unit

    open fun onScanFailed(errorCode: Int) = Unit

    companion object {
        const val SCAN_FAILED_ALREADY_STARTED = 1
        const val SCAN_FAILED_APPLICATION_REGISTRATION_FAILED = 2
        const val SCAN_FAILED_INTERNAL_ERROR = 3
        const val SCAN_FAILED_FEATURE_UNSUPPORTED = 4
        const val SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES = 5
        const val SCAN_FAILED_SCANNING_TOO_FREQUENTLY = 6
    }
}
