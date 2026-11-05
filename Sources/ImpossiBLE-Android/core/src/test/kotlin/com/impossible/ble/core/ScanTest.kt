package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Test

class ScanTest {

    private val f = Fixture()
    private val identity = Identity()
    private val scanner = Scanner(f.session, identity)
    private val singles = java.util.concurrent.CopyOnWriteArrayList<ScanResult>()
    private val batches = java.util.concurrent.CopyOnWriteArrayList<List<ScanResult>>()

    @After
    fun tearDown() = f.close()

    private fun discover(id: String, name: String, rssi: Int) = f.incoming(
        """{"type":"didDiscover","id":"$id","name":"$name","rssi":$rssi,"adv":{"kCBAdvDataLocalName":"$name"}}""",
    )

    private fun sub(reportDelay: Long = 0, filter: (String?) -> Boolean = { true }) =
        ScanSubscription(listOf("CE060000-43E5-11E4-916C-0800200C9A66"), reportDelay, filter, { singles += it }, { batches += it })

    @Test
    fun `given a discovery, then the record carries name, expanded services, manufacturer id split and service data and no raw bytes`() {
        val line = """{"type":"didDiscover","id":"E2C56DB5-DFFB-48D2-B060-D0F5A71096E0","name":"PM5","rssi":-70,"adv":{"kCBAdvDataLocalName":"PM5",""" +
            """"kCBAdvDataServiceUUIDs":["180D"],"kCBAdvDataManufacturerData":"AQIDBA==","kCBAdvDataServiceData":{"180D":"BQ=="}}}"""
        val r = scanner.toResult(Wire.decode(line) as DidDiscover)
        assertThat(r.rssi).isEqualTo(-70)
        assertThat(r.name).isEqualTo("PM5")
        assertThat(r.address).isEqualTo(identity.addressFor("E2C56DB5-DFFB-48D2-B060-D0F5A71096E0"))
        assertThat(r.record.serviceUuids).containsExactly("0000180d-0000-1000-8000-00805f9b34fb")
        assertThat(r.record.manufacturerData.keys).containsExactly(0x0201)
        assertThat(r.record.manufacturerData[0x0201]).isEqualTo(byteArrayOf(3, 4))
        assertThat(r.record.serviceData["0000180d-0000-1000-8000-00805f9b34fb"]).isEqualTo(byteArrayOf(5))
        assertThat(r.record.bytes).isNull()
    }

    @Test
    fun `given the first subscription, then one wire scan with duplicates is sent and later ones share it`() {
        val a = sub()
        val b = sub()
        scanner.start(a)
        scanner.start(b)
        f.drain()
        assertThat(f.sent).hasSize(1)
        assertThat(f.sent.single()).contains("\"type\":\"scan\"")
        scanner.stop(a)
        f.drain()
        assertThat(f.sent).hasSize(1)
        scanner.stop(b)
        f.drain()
        assertThat(f.sent.last()).contains("stopScan")
    }

    @Test
    fun `given reportDelay zero, then each result is delivered immediately`() {
        scanner.start(sub())
        discover("p", "PM5", -50)
        discover("p", "PM5", -51)
        f.drain()
        assertThat(singles.map { it.rssi }).containsExactly(-50, -51).inOrder()
        assertThat(batches).isEmpty()
    }

    @Test
    fun `given reportDelay, then results are buffered with the last per address winning and flushed as a batch`() {
        scanner.start(sub(reportDelay = 60))
        discover("p", "PM5", -50)
        discover("p", "PM5", -55)
        discover("q", "PM5 2", -60)
        f.drain()
        assertThat(singles).isEmpty()
        f.awaitThat { batches.isNotEmpty() }
        assertThat(batches.first().map { it.rssi }).containsExactly(-55, -60).inOrder()
    }

    @Test
    fun `given an empty interval, then no empty batch is delivered`() {
        scanner.start(sub(reportDelay = 30))
        Thread.sleep(120)
        assertThat(batches).isEmpty()
    }

    @Test
    fun `given a name filter, then non matching devices are dropped`() {
        scanner.start(sub(filter = { it?.startsWith("PM5") == true }))
        discover("p", "PM5 1", -50)
        discover("q", "Other", -50)
        f.drain()
        assertThat(singles.map { it.name }).containsExactly("PM5 1")
    }

    @Test
    fun `given a stopped subscription, then it receives nothing and its flush stops`() {
        val s = sub(reportDelay = 30)
        scanner.start(s)
        scanner.stop(s)
        discover("p", "PM5", -50)
        Thread.sleep(100)
        assertThat(batches).isEmpty()
        assertThat(singles).isEmpty()
    }

    @Test
    fun `given an active scan, when the transport reconnects, then the wire scan is sent again and not without subscribers`() {
        scanner.onTransportUp()
        f.drain()
        assertThat(f.sent).isEmpty()
        val a = sub()
        scanner.start(a)
        f.drain()
        scanner.onTransportUp()
        f.drain()
        assertThat(f.sent.filter { it.contains("\"type\":\"scan\"") }).hasSize(2)
        scanner.stop(a)
        f.drain()
        scanner.onTransportUp()
        f.drain()
        assertThat(f.sent.filter { it.contains("\"type\":\"scan\"") }).hasSize(2)
    }
}
