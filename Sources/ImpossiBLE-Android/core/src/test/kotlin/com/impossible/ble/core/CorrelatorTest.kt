package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class CorrelatorTest {

    private val notifications = mutableListOf<DidUpdateValue>()
    private val correlator = Correlator { notifications += it }
    private val read = Key(Kind.Read, "p", "c")

    private fun value(isNotification: Boolean?, v: Byte = 1) = DidUpdateValue("p", "c", byteArrayOf(v), "", isNotification)

    @Test
    fun `given a pending read, when a value flagged as read arrives, then the read completes and no notification fires`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(read) { got += it }
        correlator.dispatch(value(false))
        assertThat(got).hasSize(1)
        assertThat(notifications).isEmpty()
    }

    @Test
    fun `given a pending read, when a value flagged as notification arrives, then it is a notification and the read stays pending`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(read) { got += it }
        correlator.dispatch(value(true))
        assertThat(got).isEmpty()
        assertThat(notifications).hasSize(1)
        correlator.dispatch(value(false))
        assertThat(got).hasSize(1)
    }

    @Test
    fun `given a provider without the flag, then a pending read takes the first value and later values are notifications`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(read) { got += it }
        correlator.dispatch(value(null, 1))
        correlator.dispatch(value(null, 2))
        assertThat(got).hasSize(1)
        assertThat(notifications.map { it.value[0] }).containsExactly(2.toByte())
    }

    @Test
    fun `given no pending read, when a value flagged as read arrives, then it is dropped`() {
        correlator.dispatch(value(false))
        assertThat(notifications).isEmpty()
    }

    @Test
    fun `given two reads on one characteristic, then replies resolve them in order`() {
        val order = mutableListOf<Int>()
        correlator.expect(read) { order += 1 }
        correlator.expect(read) { order += 2 }
        correlator.dispatch(value(false))
        correlator.dispatch(value(false))
        assertThat(order).containsExactly(1, 2).inOrder()
    }

    @Test
    fun `given reads on two characteristics, then replies resolve only their own`() {
        val got = mutableListOf<String>()
        correlator.expect(Key(Kind.Read, "p", "a")) { got += "a" }
        correlator.expect(Key(Kind.Read, "p", "b")) { got += "b" }
        correlator.dispatch(DidUpdateValue("p", "b", byteArrayOf(), "", false))
        assertThat(got).containsExactly("b")
    }

    @Test
    fun `given a cancelled token, then a late reply does not reach the handler`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(read) { got += it }.cancel()
        correlator.dispatch(value(false))
        assertThat(got).isEmpty()
    }

    @Test
    fun `given a read that timed out, when the next read starts, then the late reply of the first is discarded and the second gets its own`() {
        val got = mutableListOf<Byte>()
        correlator.expect(read) { error("timed out request must not complete") }.cancel()
        correlator.expect(read) { got += (it as DidUpdateValue).value[0] }
        correlator.dispatch(value(false, 1))
        assertThat(got).isEmpty()
        correlator.dispatch(value(false, 2))
        assertThat(got).containsExactly(2.toByte())
    }

    @Test
    fun `given a completed read, then cancelling its token leaves no stale marker`() {
        val got = mutableListOf<Byte>()
        val token = correlator.expect(read) { got += 1 }
        correlator.dispatch(value(false))
        token.cancel()
        correlator.expect(read) { got += 2 }
        correlator.dispatch(value(false))
        assertThat(got).containsExactly(1.toByte(), 2.toByte()).inOrder()
    }

    @Test
    fun `given a timed out read whose reply never comes, then the stale marker expires and does not eat a later reply`() {
        var now = 0L
        val c = Correlator(nowNs = { now }, tombstoneTtlMs = 1_000) {}
        val got = mutableListOf<Byte>()
        c.expect(read) { }.cancel()
        now += 2_000_000_000L
        c.expect(read) { got += 3 }
        c.dispatch(value(false))
        assertThat(got).containsExactly(3.toByte())
    }

    @Test
    fun `given a timed out read, when the peripheral is lost, then the stale marker is dropped`() {
        val got = mutableListOf<Byte>()
        correlator.expect(read) { }.cancel()
        correlator.lost("p")
        correlator.expect(read) { got += 4 }
        correlator.dispatch(value(false))
        assertThat(got).containsExactly(4.toByte())
    }

    @Test
    fun `given connect replies, then both success and failure resolve the connect key`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(Key(Kind.Connect, "p")) { got += it }
        correlator.dispatch(DidFailConnect("p", "x"))
        correlator.expect(Key(Kind.Connect, "p")) { got += it }
        correlator.dispatch(DidConnect("p", null, null))
        assertThat(got.map { it::class }).containsExactly(DidFailConnect::class, DidConnect::class).inOrder()
    }

    @Test
    fun `given write and notify replies, then they resolve their keys`() {
        val got = mutableListOf<String>()
        correlator.expect(Key(Kind.Write, "p", "c")) { got += "w" }
        correlator.expect(Key(Kind.Notify, "p", "c")) { got += "n" }
        correlator.dispatch(DidWriteValue("p", "c", "", null))
        correlator.dispatch(DidUpdateNotification("p", "c", true, ""))
        assertThat(got).containsExactly("w", "n").inOrder()
    }

    @Test
    fun `given a peripheral is lost, then its connect and disconnect waiters get a disconnect and others are untouched`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(Key(Kind.Connect, "p")) { got += it }
        correlator.expect(Key(Kind.Disconnect, "p")) { got += it }
        correlator.expect(Key(Kind.Connect, "q")) { got += it }
        correlator.lost("p")
        assertThat(got).containsExactly(DidDisconnect("p", ""), DidDisconnect("p", ""))
        correlator.lost(null)
        assertThat(got).hasSize(3)
    }

    @Test
    fun `given a didDisconnect message, then connect and disconnect waiters for that peripheral resolve`() {
        val got = mutableListOf<Incoming>()
        correlator.expect(Key(Kind.Connect, "p")) { got += it }
        correlator.dispatch(DidDisconnect("p", "link lost"))
        assertThat(got).containsExactly(DidDisconnect("p", "link lost"))
    }
}
