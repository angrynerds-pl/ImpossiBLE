package com.impossible.ble.core

data class DiscoveredCharacteristic(val id: String, val uuid: String, val properties: Int)

data class DiscoveredService(val id: String, val uuid: String, val primary: Boolean, val characteristics: List<DiscoveredCharacteristic>)

internal class Discovery<D>(private val session: Session, private val id: String, private val device: D, private val stepTimeoutMs: Long) {
    private val queue = session.queueFor(id)

    fun run(onResult: (List<DiscoveredService>) -> Unit, onFailure: (Int) -> Unit) {
        step(Key(Kind.DiscoverServices, id), Wire.discoverServices(id), onFailure) { reply ->
            characteristics((reply as DidDiscoverServices).services, 0, mutableListOf(), onResult, onFailure)
        }
    }

    private fun characteristics(
        infos: List<ServiceInfo>,
        index: Int,
        acc: MutableList<DiscoveredService>,
        onResult: (List<DiscoveredService>) -> Unit,
        onFailure: (Int) -> Unit,
    ) {
        val info = infos.getOrNull(index) ?: return onResult(acc)
        step(Key(Kind.DiscoverCharacteristics, id, info.id), Wire.discoverCharacteristics(id, info.id), onFailure) { reply ->
            val found = (reply as DidDiscoverCharacteristics).characteristics.map { DiscoveredCharacteristic(it.id, it.uuid, it.properties) }
            acc += DiscoveredService(info.id, info.uuid, info.primary, found)
            characteristics(infos, index + 1, acc, onResult, onFailure)
        }
    }

    private fun step(key: Key, line: String, onFailure: (Int) -> Unit, onReply: (Incoming) -> Unit) {
        queue.request(device, false) { s ->
            s.track(session.correlator.expect(key) { reply ->
                when (errorOf(reply)) {
                    "" -> {
                        s.succeed()
                        onReply(reply)
                    }
                    null -> s.failWith(Reason.DEVICE_DISCONNECTED)
                    else -> s.failWith(Reason.REQUEST_FAILED)
                }
            })
            session.send(line)
        }.timeout(stepTimeoutMs).fail { _, status -> session.scheduler.execute { onFailure(status) } }.enqueue()
    }

    private fun errorOf(reply: Incoming): String? = when (reply) {
        is DidDiscoverServices -> reply.error
        is DidDiscoverCharacteristics -> reply.error
        else -> null
    }
}
