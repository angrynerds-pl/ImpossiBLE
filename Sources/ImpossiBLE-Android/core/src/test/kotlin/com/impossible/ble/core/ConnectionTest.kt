package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors

class ConnectionTest {

    private val server = ServerSocket().apply {
        receiveBufferSize = SMALL_BUFFER
        bind(java.net.InetSocketAddress(java.net.InetAddress.getLoopbackAddress(), 0), 1)
    }
    private val silentCloses = java.util.concurrent.atomic.AtomicInteger()
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val states = CopyOnWriteArrayList<ConnectionState>()
    private val messages = CopyOnWriteArrayList<Incoming>()
    private val connection = Connection(
        "127.0.0.1", server.localPort, Wire.hello("1", "b", "t"), scheduler,
        object : ConnectionListener {
            override fun onState(state: ConnectionState) { states += state }
            override fun onMessage(message: Incoming) { messages += message }
            override fun onClosedWithoutReply() { silentCloses.incrementAndGet() }
        },
        minBackoffMs = 20, maxBackoffMs = 80, writeStallMs = 300, watchdogTickMs = 50,
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

    @Test
    fun `given a server that never reads, then send never blocks and the stalled socket is closed and reconnected`() {
        connection.start()
        val stalled = accept()
        await { ConnectionState.Connected in states }
        val big = "x".repeat(BIG_LINE)
        var slowest = 0L
        val deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(10)
        while (states.count { it == ConnectionState.Disconnected } == 0 && System.nanoTime() < deadline) {
            val t0 = System.nanoTime()
            connection.send(big)
            slowest = maxOf(slowest, System.nanoTime() - t0)
            Thread.sleep(2)
        }
        assertThat(ConnectionState.Disconnected in states).isTrue()
        assertThat(slowest).isLessThan(java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(200))
        val second = accept()
        assertThat(second.getInputStream().bufferedReader().readLine()).contains("hello")
        second.close()
        stalled.close()
    }

    @Test
    fun `given a server that never reads but keeps sending, then the stalled writer is still detected`() {
        connection.start()
        val stalled = accept()
        await { ConnectionState.Connected in states }
        val flood = Thread {
            try {
                val out = stalled.getOutputStream()
                while (true) {
                    out.write("{\"type\":\"didUpdateValue\"}\n".toByteArray())
                    out.flush()
                    Thread.sleep(10)
                }
            } catch (ignored: java.io.IOException) {
                return@Thread
            }
        }.apply { isDaemon = true; start() }
        val big = "x".repeat(BIG_LINE)
        repeat(50) { connection.send(big) }
        await { ConnectionState.Disconnected in states }
        flood.join(5000)
        stalled.close()
    }

    @Test
    fun `given a stalled writer, then stop returns promptly`() {
        connection.start()
        val stalled = accept()
        await { ConnectionState.Connected in states }
        val big = "x".repeat(BIG_LINE)
        repeat(200) { connection.send(big) }
        val t0 = System.nanoTime()
        connection.stop()
        assertThat(System.nanoTime() - t0).isLessThan(java.util.concurrent.TimeUnit.MILLISECONDS.toNanos(500))
        stalled.close()
    }

    @Test
    fun `given the server closes right after hello without replying, then the close is reported as silent`() {
        connection.start()
        val s = accept()
        s.getInputStream().bufferedReader().readLine()
        s.close()
        await { silentCloses.get() == 1 }
    }

    @Test
    fun `given the server replied before closing, then the close is not reported as silent`() {
        connection.start()
        val s = accept()
        s.getOutputStream().write("""{"type":"didConnect","id":"a"}""".toByteArray() + "\n".toByteArray())
        s.getOutputStream().flush()
        await { messages.size == 1 }
        s.close()
        await { ConnectionState.Disconnected in states }
        assertThat(silentCloses.get()).isEqualTo(0)
    }

    @Test
    fun `given stop lands between open and publish, then the socket is closed and no hello is sent`() {
        val opened = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val racing = Connection(
            "127.0.0.1", server.localPort, Wire.hello("1", "b", "t"), scheduler,
            object : ConnectionListener {
                override fun onState(state: ConnectionState) { states += state }
                override fun onMessage(message: Incoming) { messages += message }
            },
            watchdogTickMs = 50,
            afterOpen = {
                opened.countDown()
                var done = false
                while (!done) {
                    try {
                        release.await()
                        done = true
                    } catch (ignored: InterruptedException) {
                        done = false
                    }
                }
            },
        )
        racing.start()
        val s = accept()
        assertThat(opened.await(5, java.util.concurrent.TimeUnit.SECONDS)).isTrue()
        racing.stop()
        release.countDown()
        assertThat(s.getInputStream().read()).isEqualTo(-1)
        assertThat(ConnectionState.Connected in states).isFalse()
    }

    @Test
    fun `given the send queue is full, then send returns false and the drop is reported once`() {
        val drops = CopyOnWriteArrayList<Pair<Boolean, Int>>()
        val patient = Connection(
            "127.0.0.1", server.localPort, Wire.hello("1", "b", "t"), scheduler,
            object : ConnectionListener {
                override fun onState(state: ConnectionState) { states += state }
                override fun onMessage(message: Incoming) { messages += message }
                override fun onSendDropped(queueFull: Boolean, dropped: Int) { drops += queueFull to dropped }
            },
            writeStallMs = 60_000, watchdogTickMs = 50,
        )
        patient.start()
        val silent = accept()
        await { ConnectionState.Connected in states }
        val big = "x".repeat(BIG_LINE)
        val results = (1..QUEUE_PLUS).map { patient.send(big) }
        assertThat(results.count { !it }).isGreaterThan(0)
        await { drops.isNotEmpty() }
        assertThat(drops.first().first).isTrue()
        assertThat(drops).hasSize(1)
        patient.stop()
        silent.close()
    }

    @Test
    fun `given send before connect, then the drop is reported as not connected`() {
        val drops = CopyOnWriteArrayList<Pair<Boolean, Int>>()
        val idle = Connection(
            "127.0.0.1", server.localPort, "h", scheduler,
            object : ConnectionListener {
                override fun onState(state: ConnectionState) = Unit
                override fun onMessage(message: Incoming) = Unit
                override fun onSendDropped(queueFull: Boolean, dropped: Int) { drops += queueFull to dropped }
            },
        )
        assertThat(idle.send("x")).isFalse()
        await { drops.isNotEmpty() }
        assertThat(drops.single()).isEqualTo(false to 1)
    }

    private companion object {
        const val QUEUE_PLUS = 1100
        const val SMALL_BUFFER = 4096
        const val BIG_LINE = 256 * 1024
    }
}
