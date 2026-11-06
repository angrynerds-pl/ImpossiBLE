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
