package com.impossible.ble.core

import java.io.IOException
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executor

enum class ConnectionState { Disconnected, Connecting, Connected, Rejected }

interface ConnectionListener {
    fun onState(state: ConnectionState)
    fun onMessage(message: Incoming)
}

class Connection(
    private val host: String,
    private val port: Int,
    private val hello: String,
    private val events: Executor,
    private val listener: ConnectionListener,
    private val minBackoffMs: Long = 500,
    private val maxBackoffMs: Long = 5_000,
) {
    private val lock = Any()
    private var out: OutputStream? = null
    private var socket: Socket? = null
    private var thread: Thread? = null
    private var lastState: ConnectionState? = null

    @Volatile
    private var stopped = false

    fun start() {
        thread = Thread(::run, "impossible-ble-connection").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        stopped = true
        synchronized(lock) { socket?.close() }
        thread?.interrupt()
    }

    fun send(line: String): Boolean = synchronized(lock) {
        val stream = out ?: return false
        try {
            stream.write((line + "\n").toByteArray(Charsets.UTF_8))
            stream.flush()
            true
        } catch (ignored: IOException) {
            false
        }
    }

    private fun run() {
        var backoff = minBackoffMs
        while (!stopped) {
            post(ConnectionState.Connecting)
            val connected = open()
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
            it.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MS)
        }
    } catch (ignored: IOException) {
        null
    }

    private fun serve(s: Socket): Boolean {
        synchronized(lock) {
            socket = s
            out = s.getOutputStream()
        }
        var rejected = false
        try {
            if (!send(hello)) return false
            post(ConnectionState.Connected)
            val framer = LineFramer()
            val buffer = ByteArray(BUFFER_BYTES)
            val input = s.getInputStream()
            while (!rejected) {
                val n = input.read(buffer)
                if (n < 0) break
                rejected = framer.feed(buffer, n).any { forward(Wire.decode(it)) }
            }
        } catch (ignored: IOException) {
            return false
        } finally {
            synchronized(lock) {
                out = null
                socket = null
            }
            s.close()
        }
        return rejected
    }

    private fun forward(message: Incoming): Boolean {
        if (message is ConnectionRejected && !message.retry) {
            post(ConnectionState.Rejected)
            return true
        }
        events.execute { listener.onMessage(message) }
        return false
    }

    private fun post(state: ConnectionState) {
        if (state == lastState) return
        lastState = state
        events.execute { listener.onState(state) }
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 3_000
        const val BUFFER_BYTES = 8 * 1024
    }
}
