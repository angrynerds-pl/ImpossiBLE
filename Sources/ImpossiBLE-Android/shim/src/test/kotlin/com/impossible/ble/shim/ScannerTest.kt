package com.impossible.ble.shim

import com.google.common.truth.Truth.assertThat
import com.impossible.ble.core.Identity
import com.impossible.ble.core.Scanner
import com.impossible.ble.core.Session
import com.impossible.ble.core.Wire
import no.nordicsemi.android.support.v18.scanner.BluetoothLeScannerCompat
import no.nordicsemi.android.support.v18.scanner.ScanCallback
import no.nordicsemi.android.support.v18.scanner.ScanFilter
import no.nordicsemi.android.support.v18.scanner.ScanResult
import no.nordicsemi.android.support.v18.scanner.ScanSettings
import com.impossible.ble.core.ScanRecord as CoreScanRecord
import com.impossible.ble.core.ScanResult as CoreScanResult
import no.nordicsemi.android.support.v18.scanner.FilterSpec
import no.nordicsemi.android.support.v18.scanner.accepts
import no.nordicsemi.android.support.v18.scanner.wireServices
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ScannerTest {

    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val sent = CopyOnWriteArrayList<String>()
    private val session = Session(scheduler, Executor { it.run() }) { sent += it; true }
    private val scanner = Scanner(session, Identity())
    private val compat = BluetoothLeScannerCompat { scanner }
    private val singles = CopyOnWriteArrayList<ScanResult>()
    private val batches = CopyOnWriteArrayList<List<ScanResult>>()
    private val failures = CopyOnWriteArrayList<Int>()

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            singles += result
        }

        override fun onBatchScanResults(results: MutableList<ScanResult>) {
            batches += results.toList()
        }

        override fun onScanFailed(errorCode: Int) {
            failures += errorCode
        }
    }

    @After
    fun tearDown() = scheduler.shutdownNow().let { }

    private fun drain() = scheduler.submit {}.get(WAIT_S, TimeUnit.SECONDS)

    private fun discover(id: String, name: String, rssi: Int = -60, service: String? = null) {
        val services = service?.let { ""","kCBAdvDataServiceUUIDs":["$it"]""" }.orEmpty()
        session.onMessage(
            Wire.decode("""{"type":"didDiscover","id":"$id","name":"$name","rssi":$rssi,"adv":{"kCBAdvDataLocalName":"$name"$services}}"""),
        )
        drain()
    }

    @Test
    fun `given no report delay, when a peripheral is discovered, then the result carries device name address and rssi`() {
        compat.startScan(emptyList(), ScanSettings.Builder().setReportDelay(0).build(), callback)
        drain()
        discover("A", "PM5 430000123", -70)
        val result = singles.single()
        assertThat(result.device.name).isEqualTo("PM5 430000123")
        assertThat(result.device.address).matches("02(:[0-9A-F]{2}){5}")
        assertThat(result.rssi).isEqualTo(-70)
        assertThat(sent.single()).contains("\"scan\"")
    }

    @Test
    fun `given a report delay, when a peripheral is seen twice, then one batch holds the last result`() {
        compat.startScan(emptyList(), ScanSettings.Builder().setReportDelay(DELAY_MS).build(), callback)
        drain()
        discover("A", "PM5 1", -80)
        discover("A", "PM5 1", -50)
        Thread.sleep(DELAY_MS * 3)
        assertThat(singles).isEmpty()
        assertThat(batches.single().single().rssi).isEqualTo(-50)
    }

    @Test
    fun `given a name filter, when other peripherals are discovered, then they are dropped`() {
        val filters = listOf(ScanFilter.Builder().setDeviceName("PM5 1").build())
        compat.startScan(filters, ScanSettings.Builder().build(), callback)
        drain()
        discover("A", "PM5 1")
        discover("B", "Other")
        assertThat(singles.map { it.device.name }).containsExactly("PM5 1")
    }

    private fun result(name: String, vararg services: String) =
        CoreScanResult("02:00:00:00:00:01", name, -60, CoreScanRecord(name, services.toList(), emptyMap(), emptyMap()))

    @Test
    fun `given a name only filter and a service only filter, then a device matching either is accepted and the wire scan is unfiltered`() {
        val specs = listOf(FilterSpec("PM5 1", null), FilterSpec(null, HR))
        assertThat(accepts(specs, result("PM5 1"))).isTrue()
        assertThat(accepts(specs, result("Strap", HR))).isTrue()
        assertThat(accepts(specs, result("Other", "00001800-0000-1000-8000-00805f9b34fb"))).isFalse()
        assertThat(wireServices(specs)).isEmpty()
    }

    @Test
    fun `given one filter with name and service, then both must match and the wire scan carries the service`() {
        val specs = listOf(FilterSpec("PM5 1", HR))
        assertThat(accepts(specs, result("PM5 1", HR.uppercase()))).isTrue()
        assertThat(accepts(specs, result("PM5 1"))).isFalse()
        assertThat(accepts(specs, result("Other", HR))).isFalse()
        assertThat(wireServices(specs)).containsExactly(HR)
    }

    @Test
    fun `given no filters, then everything is accepted`() {
        assertThat(accepts(emptyList(), result("x"))).isTrue()
        assertThat(wireServices(emptyList())).isEmpty()
    }

    @Test
    fun `given a running scan, when stopped, then the wire scan stops and results cease`() {
        compat.startScan(emptyList(), ScanSettings.Builder().build(), callback)
        drain()
        compat.stopScan(callback)
        drain()
        discover("A", "PM5 1")
        assertThat(sent.last()).contains("stopScan")
        assertThat(singles).isEmpty()
    }

    @Test
    fun `given the library is not configured, when a scan starts, then it throws an illegal state`() {
        val unconfigured = BluetoothLeScannerCompat { error("ImpossibleBle.configure was not called") }
        assertThrows(IllegalStateException::class.java) { unconfigured.startScan(emptyList(), ScanSettings.Builder().build(), callback) }
    }

    private companion object {
        const val HR = "0000180d-0000-1000-8000-00805f9b34fb"
        const val WAIT_S = 5L
        const val DELAY_MS = 60L
    }
}
