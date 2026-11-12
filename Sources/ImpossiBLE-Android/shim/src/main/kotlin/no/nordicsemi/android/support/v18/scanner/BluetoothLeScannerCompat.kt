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
        val specs = active.map { FilterSpec(it.deviceName, it.serviceUuid?.uuid?.toString()) }
        val subscription = ScanSubscription(
            services = wireServices(specs),
            reportDelayMs = settings.reportDelayMillis,
            accept = { result -> accepts(specs, result) },
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

internal class FilterSpec(val name: String?, val serviceUuid: String?)

// The provider can only filter by service, so any filter without one makes the wire scan unfiltered.
internal fun wireServices(specs: List<FilterSpec>): List<String> =
    if (specs.any { it.serviceUuid == null }) emptyList() else specs.mapNotNull { it.serviceUuid }

// Nordic semantics: a filter ANDs the fields it sets, the filter list ORs.
internal fun accepts(specs: List<FilterSpec>, result: CoreScanResult): Boolean =
    specs.isEmpty() || specs.any { spec ->
        (spec.name == null || spec.name == result.name) &&
            (spec.serviceUuid == null || result.record.serviceUuids.any { it.equals(spec.serviceUuid, ignoreCase = true) })
    }
