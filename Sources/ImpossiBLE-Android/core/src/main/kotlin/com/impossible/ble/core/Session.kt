package com.impossible.ble.core

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.ScheduledExecutorService

interface Peer {
    fun onDisconnected(error: String, transportLost: Boolean)
}

class Session(
    internal val scheduler: ScheduledExecutorService,
    internal val callbacks: Executor,
    private val requestTimeoutMs: Long = DEFAULT_REQUEST_TIMEOUT_MS,
    private val sender: (String) -> Boolean,
) {
    private val notificationCallbacks = HashMap<Pair<String, String>, (ByteArray) -> Unit>()
    private val limits = ConcurrentHashMap<String, DidConnect>()
    private val queues = HashMap<String, RequestQueue>()
    private val peers = HashMap<String, Peer>()

    val correlator = Correlator { message ->
        notificationCallbacks[message.id to message.characteristicId]?.let { callback ->
            callbacks.execute { callback(message.value) }
        }
    }

    var discoverListener: ((DidDiscover) -> Unit)? = null

    fun send(line: String): Boolean = sender(line)

    fun queueFor(id: String): RequestQueue = synchronized(queues) { queues.getOrPut(id) { RequestQueue(scheduler, callbacks, requestTimeoutMs) } }

    fun register(id: String, peer: Peer) {
        synchronized(peers) { peers[id] = peer }
    }

    private fun peerList(): List<Peer> = synchronized(peers) { peers.values.toList() }

    fun setNotificationCallback(id: String, characteristicId: String, callback: (ByteArray) -> Unit) {
        scheduler.execute { notificationCallbacks[id to characteristicId] = callback }
    }

    fun recordLimits(message: DidConnect) {
        limits[message.id] = message
    }

    fun maxWrite(id: String, withResponse: Boolean): Int {
        val l = limits[id]
        return (if (withResponse) l?.maxWriteWithResponse else l?.maxWriteWithoutResponse) ?: DEFAULT_WRITE_LIMIT
    }

    fun onMessage(message: Incoming) {
        scheduler.execute {
            when (message) {
                is DidDiscover -> discoverListener?.invoke(message)
                is DidDisconnect -> {
                    queueFor(message.id).abortNow()
                    synchronized(peers) { peers[message.id] }?.onDisconnected(message.error, false)
                    correlator.dispatch(message)
                }
                is DidConnect -> {
                    recordLimits(message)
                    correlator.dispatch(message)
                }
                else -> correlator.dispatch(message)
            }
        }
    }

    fun shutdown() {
        scheduler.execute {
            lose()
            scheduler.shutdownNow()
        }
    }

    fun onTransportLost() {
        scheduler.execute(::lose)
    }

    private fun lose() {
        synchronized(queues) { queues.values.toList() }.forEach { it.abortNow() }
        peerList().forEach { it.onDisconnected("", true) }
        correlator.lost(null)
    }

    companion object {
        const val DEFAULT_REQUEST_TIMEOUT_MS = 15_000L
        private const val DEFAULT_WRITE_LIMIT = 20
    }
}
