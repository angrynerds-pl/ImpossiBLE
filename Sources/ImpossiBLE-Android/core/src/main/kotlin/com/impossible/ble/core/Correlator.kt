package com.impossible.ble.core

enum class Kind { Connect, Disconnect, Read, Write, Notify, DiscoverServices, DiscoverCharacteristics }

private val LOSS_KINDS = setOf(Kind.Connect, Kind.Disconnect, Kind.DiscoverServices, Kind.DiscoverCharacteristics)

data class Key(val kind: Kind, val id: String, val characteristicId: String = "")

class Token internal constructor(private val cancelAction: () -> Unit) {
    fun cancel() = cancelAction()
}

class Correlator(private val onNotification: (DidUpdateValue) -> Unit) {
    private class Pending(val handler: (Incoming) -> Unit)

    private val pending = HashMap<Key, ArrayDeque<Pending>>()

    fun expect(key: Key, handler: (Incoming) -> Unit): Token {
        val entry = Pending(handler)
        pending.getOrPut(key) { ArrayDeque() }.addLast(entry)
        return Token { pending[key]?.remove(entry) }
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
        val entry = pending[key]?.removeFirstOrNull() ?: return false
        entry.handler(message)
        return true
    }
}
