package com.impossible.ble.core

import java.util.concurrent.TimeUnit

enum class Kind { Connect, Disconnect, Read, Write, Notify, DiscoverServices, DiscoverCharacteristics }

private val LOSS_KINDS = setOf(Kind.Connect, Kind.Disconnect, Kind.DiscoverServices, Kind.DiscoverCharacteristics)
private val ECHO_KINDS = setOf(Kind.Read, Kind.Write, Kind.Notify)

data class Key(val kind: Kind, val id: String, val characteristicId: String = "")

class Token internal constructor(private val cancelAction: () -> Unit) {
    fun cancel() = cancelAction()
}

class Correlator(
    private val nowNs: () -> Long = System::nanoTime,
    private val tombstoneTtlMs: Long = TOMBSTONE_TTL_MS,
    private val onNotification: (DidUpdateValue) -> Unit,
) {
    private class Pending(var handler: ((Incoming) -> Unit)?, var expiresNs: Long = 0)

    private val pending = HashMap<Key, ArrayDeque<Pending>>()

    fun expect(key: Key, handler: (Incoming) -> Unit): Token {
        val entry = Pending(handler)
        pending.getOrPut(key) { ArrayDeque() }.addLast(entry)
        return Token { cancel(key, entry) }
    }

    // The wire has no request ids for reads, writes and notify toggles. A waiter cancelled while still unanswered
    // keeps its place as a marker that swallows its own late reply, so that reply cannot complete the next waiter
    // on the same key. Markers expire (a reply that never comes must not shift every later reply) and die with the link.
    private fun cancel(key: Key, entry: Pending) {
        val queue = pending[key] ?: return
        val index = queue.indexOf(entry)
        if (index < 0) return
        if (key.kind in ECHO_KINDS) {
            entry.handler = null
            entry.expiresNs = nowNs() + TimeUnit.MILLISECONDS.toNanos(tombstoneTtlMs)
        } else {
            queue.removeAt(index)
        }
    }

    fun dispatch(message: Incoming) {
        when (message) {
            is DidConnect -> resolve(Key(Kind.Connect, message.id), message)
            is DidFailConnect -> resolve(Key(Kind.Connect, message.id), message)
            is DidDiscoverServices -> resolve(Key(Kind.DiscoverServices, message.id), message)
            is DidDiscoverCharacteristics -> resolve(Key(Kind.DiscoverCharacteristics, message.id, message.serviceId), message)
            is DidDisconnect -> lost(message.id, message)
            is DidWriteValue -> resolve(Key(Kind.Write, message.id, message.characteristicId), message)
            is DidUpdateNotification -> resolve(Key(Kind.Notify, message.id, message.characteristicId), message)
            is DidUpdateValue -> dispatchValue(message)
            else -> Unit
        }
    }

    fun lost(id: String?, message: DidDisconnect? = null) {
        val keys = pending.keys.filter { it.kind in LOSS_KINDS && (id == null || it.id == id) }
        keys.forEach { key -> while (resolve(key, message ?: DidDisconnect(key.id, ""))) Unit }
        pending.keys.filter { it.kind in ECHO_KINDS && (id == null || it.id == id) }.forEach { pending.remove(it) }
    }

    private fun dispatchValue(message: DidUpdateValue) {
        val key = Key(Kind.Read, message.id, message.characteristicId)
        when (message.isNotification) {
            true -> onNotification(message)
            false -> resolve(key, message)
            null -> if (!resolve(key, message)) onNotification(message)
        }
    }

    private fun resolve(key: Key, message: Incoming): Boolean {
        val queue = pending[key] ?: return false
        while (true) {
            val entry = queue.removeFirstOrNull() ?: return false
            val handler = entry.handler
            if (handler != null) {
                handler(message)
                return true
            }
            if (entry.expiresNs - nowNs() > 0) return true
        }
    }
}

private const val TOMBSTONE_TTL_MS = 30_000L
