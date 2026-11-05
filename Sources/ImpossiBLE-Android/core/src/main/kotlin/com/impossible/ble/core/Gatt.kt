package com.impossible.ble.core

object Chunker {
    fun split(data: ByteArray, limit: Int): List<ByteArray> {
        require(limit > 0) { "limit must be positive" }
        if (data.isEmpty()) return listOf(data)
        return (data.indices step limit).map { data.copyOfRange(it, minOf(it + limit, data.size)) }
    }
}

class Gatt<D>(private val session: Session, private val id: String, private val device: D) {
    private val queue = session.queueFor(id)

    fun connect() = queue.request(device, false) { r ->
        r.track(session.correlator.expect(Key(Kind.Connect, id)) { reply ->
            if (reply is DidConnect) {
                session.recordLimits(reply)
                r.succeed()
            } else {
                r.failWith(Reason.DEVICE_DISCONNECTED)
            }
        })
        session.send(Wire.connect(id))
    }.timeout(CONNECT_TIMEOUT_MS)

    fun disconnect() = queue.request(device, false) { r ->
        r.track(session.correlator.expect(Key(Kind.Disconnect, id)) { r.succeed() })
        session.send(Wire.cancel(id))
    }

    fun read(characteristicId: String) = queue.request(device, true) { r ->
        r.track(session.correlator.expect(Key(Kind.Read, id, characteristicId)) { reply ->
            reply as DidUpdateValue
            if (reply.error.isEmpty()) {
                r.value = reply.value
                r.succeed()
            } else {
                r.failWith(Reason.GATT_ERROR)
            }
        })
        session.send(Wire.read(id, characteristicId))
    }

    fun write(characteristicId: String, data: ByteArray, withResponse: Boolean) = writeChunks(characteristicId, listOf(data), withResponse)

    fun writeSplit(characteristicId: String, data: ByteArray, withResponse: Boolean) =
        writeChunks(characteristicId, Chunker.split(data, session.maxWrite(id, withResponse)), withResponse)

    fun setNotify(characteristicId: String, enabled: Boolean) = queue.request(device, true) { r ->
        r.track(session.correlator.expect(Key(Kind.Notify, id, characteristicId)) { reply ->
            if ((reply as DidUpdateNotification).error.isEmpty()) r.succeed() else r.failWith(Reason.GATT_ERROR)
        })
        session.send(Wire.setNotify(id, characteristicId, enabled))
    }

    private fun writeChunks(characteristicId: String, chunks: List<ByteArray>, withResponse: Boolean) = queue.request(device, true) { r ->
        var next = 0
        fun sendNext() {
            r.track(session.correlator.expect(Key(Kind.Write, id, characteristicId)) { reply ->
                when {
                    (reply as DidWriteValue).error.isNotEmpty() -> r.failWith(Reason.GATT_ERROR)
                    next == chunks.size -> r.succeed()
                    else -> sendNext()
                }
            })
            session.send(Wire.write(id, characteristicId, chunks[next++], withResponse))
        }
        sendNext()
    }

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
    }
}

private fun Request<*>.track(token: Token) = onFinished { token.cancel() }
