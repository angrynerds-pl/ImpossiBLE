package com.impossible.ble.core

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

enum class ConnectionState { Disconnected, Connecting, Connected, Rejected }

interface ConnectionListener {
    fun onState(state: ConnectionState)
    fun onMessage(message: Incoming)
    fun onClosedWithoutReply() {}
    fun onSendDropped(queueFull: Boolean, dropped: Int) {}
}

class Connection(
    private val host: String,
    private val port: Int,
    private val hello: String,
    private val events: Executor,
    private val listener: ConnectionListener,
    private val minBackoffMs: Long = 500,
    private val maxBackoffMs: Long = 5_000,
    private val writeStallMs: Long = 10_000,
    private val watchdogTickMs: Long = 1_000,
    private val afterOpen: () -> Unit = {},
) {
    private class Active(val socket: Socket) {
        val lines = LinkedBlockingQueue<String>(QUEUE_CAPACITY)

        @Volatile
        var writeStartedNs = 0L

        @Volatile
        var received = false
    }

    private var thread: Thread? = null
    private var lastState: ConnectionState? = null

    @Volatile
    private var active: Active? = null

    @Volatile
    private var stopped = false

    private val dropped = AtomicInteger()
    private val lastDropReportNs = AtomicLong(System.nanoTime() - DROP_REPORT_NS)

    fun start() {
        thread = Thread(::run, "impossible-ble-connection").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        stopped = true
        active?.socket?.closeQuietly()
        thread?.interrupt()
    }

    // ponytail: writes are queued to a per-socket writer thread, so send() never blocks; false means not connected or the queue is full
    fun send(line: String): Boolean {
        val a = active
        val accepted = a?.lines?.offer(line) == true
        if (!accepted) noteDrop(queueFull = a != null)
        return accepted
    }

    private fun noteDrop(queueFull: Boolean) {
        dropped.incrementAndGet()
        val now = System.nanoTime()
        val last = lastDropReportNs.get()
        if (now - last >= DROP_REPORT_NS && lastDropReportNs.compareAndSet(last, now)) {
            val count = dropped.getAndSet(0)
            post { listener.onSendDropped(queueFull, count) }
        }
    }

    private fun run() {
        var backoff = minBackoffMs
        while (!stopped) {
            post(ConnectionState.Connecting)
            val connected = open()
            if (connected != null) afterOpen()
            if (connected != null) {
                backoff = minBackoffMs
                if (serve(connected)) return
            }
            if (stopped) return
            post(ConnectionState.Disconnected)
            try {
                Thread.sleep(backoff)
            } catch (ignored: InterruptedException) {
                return
            }
            backoff = minOf(backoff * 2, maxBackoffMs)
        }
    }

    private fun open(): Socket? = try {
        Socket().also {
            it.tcpNoDelay = true
            it.keepAlive = true
            it.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
            it.soTimeout = watchdogTickMs.toInt()
        }
    } catch (ignored: IOException) {
        null
    }

    private fun serve(s: Socket): Boolean {
        val a = Active(s)
        val writer = Thread({ writeLoop(a) }, "impossible-ble-writer").apply { isDaemon = true }
        a.lines.offer(hello)
        active = a
        if (stopped) {
            active = null
            s.closeQuietly()
            return false
        }
        writer.start()
        var rejected = false
        try {
            post(ConnectionState.Connected)
            val framer = LineFramer()
            val buffer = ByteArray(BUFFER_BYTES)
            val input = s.getInputStream()
            var n = readChunk(a, input, buffer)
            while (n >= 0 && !rejected) {
                a.received = true
                rejected = framer.feed(buffer, n).any { forward(Wire.decode(it)) }
                if (!rejected) n = readChunk(a, input, buffer)
            }
        } catch (ignored: IOException) {
            return false
        } finally {
            active = null
            writer.interrupt()
            s.closeQuietly()
            if (!a.received && !rejected && !stopped) post { listener.onClosedWithoutReply() }
        }
        return rejected
    }

    private fun readChunk(a: Active, input: java.io.InputStream, buffer: ByteArray): Int {
        var n = TICK
        while (n == TICK) {
            n = try {
                input.read(buffer)
            } catch (ignored: SocketTimeoutException) {
                if (stopped || stalled(a)) -1 else TICK
            }
        }
        return n
    }

    private fun stalled(a: Active): Boolean {
        val started = a.writeStartedNs
        return started != 0L && System.nanoTime() - started > TimeUnit.MILLISECONDS.toNanos(writeStallMs)
    }

    private fun writeLoop(a: Active) {
        try {
            val out = a.socket.getOutputStream()
            while (true) {
                val line = a.lines.take()
                a.writeStartedNs = System.nanoTime()
                out.write((line + "\n").toByteArray(Charsets.UTF_8))
                out.flush()
                a.writeStartedNs = 0L
            }
        } catch (ignored: IOException) {
            a.socket.closeQuietly()
        } catch (ignored: InterruptedException) {
            return
        }
    }

    private fun forward(message: Incoming): Boolean {
        if (message is ConnectionRejected && !message.retry) {
            post(ConnectionState.Rejected)
            return true
        }
        post { listener.onMessage(message) }
        return false
    }

    private fun post(state: ConnectionState) {
        if (state == lastState) return
        lastState = state
        post { listener.onState(state) }
    }

    private fun post(block: () -> Unit) {
        if (stopped) return
        try {
            events.execute(block)
        } catch (ignored: RejectedExecutionException) {
            return
        }
    }

    private fun Socket.closeQuietly() {
        try {
            close()
        } catch (ignored: IOException) {
            return
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 3_000
        const val BUFFER_BYTES = 8 * 1024
        const val QUEUE_CAPACITY = 1024
        const val TICK = -2
        val DROP_REPORT_NS = TimeUnit.SECONDS.toNanos(1)
    }
}
