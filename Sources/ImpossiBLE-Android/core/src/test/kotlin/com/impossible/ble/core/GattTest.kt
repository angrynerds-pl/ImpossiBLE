package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class GattTest {

    private val f = Fixture()
    private val gatt = Gatt(f.session, "p", "dev")
    private val events = java.util.concurrent.CopyOnWriteArrayList<String>()

    @After
    fun tearDown() = f.close()

    private fun sentTypes() = f.sent.map { Regex("\"type\":\"(\\w+)\"").find(it)?.groupValues?.get(1) }

    private fun connected(withResponse: Int? = 512, withoutResponse: Int? = 182) {
        val limits = listOfNotNull(
            withResponse?.let { ",\"maxWriteWithResponse\":$it" },
            withoutResponse?.let { ",\"maxWriteWithoutResponse\":$it" },
        ).joinToString("")
        f.incoming("""{"type":"didConnect","id":"p"$limits}""")
    }

    @Test
    fun `given connect, then connect is sent and didConnect completes it with the write limits recorded`() {
        gatt.connect().done { events += "done" }.enqueue()
        f.drain()
        assertThat(sentTypes()).containsExactly("connect")
        connected()
        assertThat(events).containsExactly("done")
        assertThat(f.session.maxWrite("p", true)).isEqualTo(512)
        assertThat(f.session.maxWrite("p", false)).isEqualTo(182)
    }

    @Test
    fun `given a provider without limits, then the default write limit is 20`() {
        connected(null, null)
        assertThat(f.session.maxWrite("p", true)).isEqualTo(20)
    }

    @Test
    fun `given didFailConnect, then connect await throws DeviceDisconnectedException`() {
        val t = Thread { f.awaitThat { f.sent.isNotEmpty() }; f.incoming("""{"type":"didFailConnect","id":"p","error":"x"}""") }
        t.start()
        assertThrows(DeviceDisconnectedException::class.java) { gatt.connect().await() }
    }

    @Test
    fun `given connect awaited, when the peripheral disconnects mid-await, then await throws DeviceDisconnectedException`() {
        val t = Thread { f.awaitThat { f.sent.isNotEmpty() }; f.incoming("""{"type":"didDisconnect","id":"p","error":"link"}""") }
        t.start()
        assertThrows(DeviceDisconnectedException::class.java) { gatt.connect().await() }
    }

    @Test
    fun `given connect awaited, when the transport drops mid-await, then await throws DeviceDisconnectedException`() {
        val t = Thread { f.awaitThat { f.sent.isNotEmpty() }; f.session.onTransportLost(); f.drain() }
        t.start()
        assertThrows(DeviceDisconnectedException::class.java) { gatt.connect().await() }
    }

    @Test
    fun `given connect times out, then it fails with the timeout reason`() {
        val e = assertThrows(RequestFailedException::class.java) { gatt.connect().timeout(40).await() }
        assertThat(e.status).isEqualTo(Reason.TIMEOUT)
    }

    @Test
    fun `given disconnect, then cancel is sent and didDisconnect completes it`() {
        gatt.disconnect().done { events += "done" }.enqueue()
        f.drain()
        assertThat(sentTypes()).containsExactly("cancel")
        f.incoming("""{"type":"didDisconnect","id":"p","error":""}""")
        assertThat(events).containsExactly("done")
    }

    @Test
    fun `given a read, then the value reaches the request and notifications for the same characteristic are routed apart`() {
        val notes = mutableListOf<String>()
        f.session.setNotificationCallback("p", "c") { notes += it.joinToString(",") }
        val r = gatt.read("c").done { events += "done" }
        r.enqueue()
        f.drain()
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"BQ==","error":"","isNotification":true}""")
        assertThat(events).isEmpty()
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"AQI=","error":"","isNotification":false}""")
        assertThat(events).containsExactly("done")
        assertThat(r.value).isEqualTo(byteArrayOf(1, 2))
        assertThat(notes).containsExactly("5")
    }

    @Test
    fun `given a read error, then it fails with a gatt error`() {
        val r = gatt.read("c").fail { _, s -> events += "fail$s" }
        r.enqueue()
        f.drain()
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"","error":"nope","isNotification":false}""")
        assertThat(events).containsExactly("fail${Reason.GATT_ERROR}")
    }

    @Test
    fun `given a read with no reply, then it times out and a late reply is ignored`() {
        val r = gatt.read("c").timeout(30).fail { _, s -> events += "fail$s" }.done { events += "done" }
        r.enqueue()
        f.awaitThat { events.isNotEmpty() }
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"AQ==","error":"","isNotification":false}""")
        assertThat(events).containsExactly("fail${Reason.TIMEOUT}")
    }

    @Test
    fun `given two reads queued, then the second read is sent only after the first reply`() {
        gatt.read("a").enqueue()
        gatt.read("b").enqueue()
        f.drain()
        assertThat(sentTypes()).containsExactly("read")
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"a","value":"","error":"","isNotification":false}""")
        assertThat(sentTypes()).containsExactly("read", "read")
    }

    @Test
    fun `given a write with response, then it completes on didWriteValue and an error maps to a gatt error`() {
        gatt.write("c", byteArrayOf(9), true).done { events += "done" }.enqueue()
        gatt.write("c", byteArrayOf(9), true).fail { _, s -> events += "fail$s" }.enqueue()
        f.drain()
        f.incoming("""{"type":"didWriteValue","id":"p","characteristicId":"c","error":""}""")
        f.incoming("""{"type":"didWriteValue","id":"p","characteristicId":"c","error":"denied"}""")
        assertThat(events).containsExactly("done", "fail${Reason.GATT_ERROR}").inOrder()
    }

    @Test
    fun `given a write without response, then it completes on the readiness reply and times out without one`() {
        gatt.write("c", byteArrayOf(9), false).done { events += "done" }.enqueue()
        f.drain()
        assertThat(f.sent.single()).contains("\"writeType\":1")
        f.incoming("""{"type":"didWriteValue","id":"p","characteristicId":"c","error":"","writeType":1}""")
        assertThat(events).containsExactly("done")
        val e = assertThrows(RequestFailedException::class.java) { gatt.write("c", byteArrayOf(9), false).timeout(30).await() }
        assertThat(e.status).isEqualTo(Reason.TIMEOUT)
    }

    @Test
    fun `given a split write, then chunks follow the reported limit one at a time each after its ack`() {
        connected(withResponse = 4, withoutResponse = 4)
        f.sent.clear()
        gatt.writeSplit("c", ByteArray(10) { it.toByte() }, true).done { events += "done" }.enqueue()
        f.drain()
        val ack = """{"type":"didWriteValue","id":"p","characteristicId":"c","error":""}"""
        assertThat(f.sent).hasSize(1)
        f.incoming(ack)
        assertThat(f.sent).hasSize(2)
        assertThat(events).isEmpty()
        f.incoming(ack)
        assertThat(f.sent).hasSize(3)
        f.incoming(ack)
        assertThat(events).containsExactly("done")
        val payloads = f.sent.map { Regex("\"value\":\"([^\"]*)\"").find(it)?.groupValues?.get(1) }
        assertThat(payloads).containsExactly("AAECAw==", "BAUGBw==", "CAk=").inOrder()
    }

    @Test
    fun `given a split write that fails on a chunk, then no further chunk is sent`() {
        connected(withResponse = 2, withoutResponse = 2)
        f.sent.clear()
        gatt.writeSplit("c", ByteArray(6), true).fail { _, s -> events += "fail$s" }.enqueue()
        f.drain()
        f.incoming("""{"type":"didWriteValue","id":"p","characteristicId":"c","error":"x"}""")
        assertThat(f.sent).hasSize(1)
        assertThat(events).containsExactly("fail${Reason.GATT_ERROR}")
    }

    @Test
    fun `given setNotify, then done fires only on didUpdateNotification`() {
        gatt.setNotify("c", true).done { events += "done" }.enqueue()
        f.drain()
        assertThat(f.sent.single()).contains("\"enabled\":true")
        assertThat(events).isEmpty()
        f.incoming("""{"type":"didUpdateNotification","id":"p","characteristicId":"c","enabled":true,"error":""}""")
        assertThat(events).containsExactly("done")
    }

    @Test
    fun `given a queued write, when the peripheral disconnects mid-await, then the in-flight op fails and the queued write await throws device disconnected`() {
        gatt.read("c").fail { _, s -> events += "fail$s" }.enqueue()
        val write = gatt.write("c", byteArrayOf(1), true)
        var thrown = false
        val returned = CountDownLatch(1)
        val t = Thread {
            try {
                write.await()
            } catch (ignored: DeviceDisconnectedException) {
                thrown = true
            }
            returned.countDown()
        }
        t.isDaemon = true
        t.start()
        f.awaitThat { f.session.queueFor("p").queuedCount() == 2 }
        f.incoming("""{"type":"didDisconnect","id":"p","error":"link"}""")
        assertThat(events).containsExactly("fail${Reason.DEVICE_DISCONNECTED}")
        assertThat(returned.await(Fixture.WAIT_S, TimeUnit.SECONDS)).isTrue()
        assertThat(thrown).isTrue()
    }

    @Test
    fun `given the transport drops, then queued work of every peripheral is aborted`() {
        gatt.read("c").fail { _, s -> events += "fail$s" }.enqueue()
        f.drain()
        f.session.onTransportLost()
        f.drain()
        assertThat(events).containsExactly("fail${Reason.DEVICE_DISCONNECTED}")
    }
}
