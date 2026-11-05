package no.nordicsemi.android.support.v18.scanner

import com.impossible.ble.BleDevice
import com.impossible.ble.ImpossibleBle
import com.impossible.ble.core.Scanner
import com.impossible.ble.core.ScanResult as CoreScanResult
import com.impossible.ble.core.ScanSubscription

open class BluetoothLeScannerCompat internal constructor(private val scanner: () -> Scanner) {
    private val subscriptions = HashMap<ScanCallback, ScanSubscription>()

    fun startScan(filters: List<ScanFilter>?, settings: ScanSettings, callback: ScanCallback) {
        val core = scanner()
        val active = filters.orEmpty()
        val names = active.mapNotNull { it.deviceName }
        val subscription = ScanSubscription(
            services = active.mapNotNull { it.serviceUuid?.uuid?.toString() },
            reportDelayMs = settings.reportDelayMillis,
            nameFilter = { name -> names.isEmpty() || name in names },
            onResult = { callback.onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, convert(it)) },
            onBatch = { batch -> callback.onBatchScanResults(batch.map(::convert).toMutableList()) },
        )
        synchronized(subscriptions) { subscriptions.put(callback, subscription) }?.let(core::stop)
        core.start(subscription)
    }

    fun startScan(callback: ScanCallback) = startScan(null, ScanSettings.Builder().build(), callback)

    fun stopScan(callback: ScanCallback) {
        val subscription = synchronized(subscriptions) { subscriptions.remove(callback) } ?: return
        scanner().stop(subscription)
    }

    private fun convert(result: CoreScanResult) = ScanResult(
        BleDevice(result.address, result.name),
        result.rssi,
        ScanRecord(result.record.deviceName, result.record.serviceUuids),
        System.nanoTime(),
    )

    companion object {
        private val instance by lazy { BluetoothLeScannerCompat { ImpossibleBle.scanner() } }

        @JvmStatic
        fun getScanner(): BluetoothLeScannerCompat = instance
    }
}
