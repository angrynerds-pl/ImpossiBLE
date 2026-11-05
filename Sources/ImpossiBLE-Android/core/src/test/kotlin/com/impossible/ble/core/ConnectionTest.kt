package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

class ConnectionTest {

    private val server = ServerSocket(0, 1, java.net.InetAddress.getLoopbackAddress())
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val states = CopyOnWriteArrayList<ConnectionState>()
    private val messages = CopyOnWriteArrayList<Incoming>()
    private val connection = Connection(
        "127.0.0.1", server.localPort, Wire.hello("1", "b", "t"), scheduler,
        object : ConnectionListener {
            override fun onState(state: ConnectionState) { states += state }
            override fun onMessage(message: Incoming) { messages += message }
        },
        minBackoffMs = 20, maxBackoffMs = 80,
    )

    @After
    fun tearDown() {
        connection.stop()
        server.close()
        scheduler.shutdownNow()
    }

    private fun await(c: () -> Boolean) = Fixture().also { it.awaitThat(c) }.close()

    private fun accept(): Socket = server.accept().also { it.soTimeout = 5000 }

    @Test
    fun `given start, then hello is the first line and state becomes Connected`() {
        connection.start()
        val s = accept()
        val first = s.getInputStream().bufferedReader().readLine()
        assertThat(first).contains("\"type\":\"hello\"")
        assertThat(first).contains("\"pid\":0")
        await { ConnectionState.Connected in states }
        s.close()
    }

    @Test
    fun `given partial and merged lines from the server, then messages decode in order`() {
        connection.start()
        val s = accept()
        val out = s.getOutputStream()
        out.write("""{"type":"didConnect","id":"a"}""".toByteArray().let { it.copyOfRange(0, 10) })
        out.flush()
        Thread.sleep(30)
        out.write(("""{"type":"didConnect","id":"a"}""".substring(10) + "\n" + """{"type":"didFailConnect","id":"b","error":""}""" + "\n").toByteArray())
        out.flush()
        await { messages.size == 2 }
        assertThat(messages[0]).isEqualTo(DidConnect("a", null, null))
        assertThat(messages[1]).isEqualTo(DidFailConnect("b", ""))
        s.close()
    }

    @Test
    fun `given send, then the line reaches the server newline terminated`() {
        connection.start()
        val s = accept()
        val reader = s.getInputStream().bufferedReader()
        reader.readLine()
        await { connection.send(Wire.stopScan()) }
        assertThat(reader.readLine()).isEqualTo(Wire.stopScan())
        s.close()
    }

    @Test
    fun `given send before connect, then it returns false`() {
        assertThat(connection.send("x")).isFalse()
    }

    @Test
    fun `given the server closes, then state goes Disconnected and the client reconnects with a fresh hello`() {
        connection.start()
        accept().close()
        await { ConnectionState.Disconnected in states }
        val s2 = accept()
        assertThat(s2.getInputStream().bufferedReader().readLine()).contains("hello")
        await { states.count { it == ConnectionState.Connected } == 2 }
        s2.close()
    }

    @Test
    fun `given connectionRejected with retry false, then state is Rejected and there is no reconnect`() {
        connection.start()
        val s = accept()
        s.getOutputStream().write("{\"type\":\"connectionRejected\",\"retry\":false}\n".toByteArray())
        s.getOutputStream().flush()
        await { ConnectionState.Rejected in states }
        s.close()
        server.soTimeout = 300
        val second = runCatching { server.accept() }
        assertThat(second.isFailure).isTrue()
        assertThat(states.last()).isEqualTo(ConnectionState.Rejected)
    }

    @Test
    fun `given stop, then no reconnect happens`() {
        connection.start()
        val s = accept()
        await { ConnectionState.Connected in states }
        connection.stop()
        s.close()
        server.soTimeout = 300
        assertThat(runCatching { server.accept() }.isFailure).isTrue()
    }
}
