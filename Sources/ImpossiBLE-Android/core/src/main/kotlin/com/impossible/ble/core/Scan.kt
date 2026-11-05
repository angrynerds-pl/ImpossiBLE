package com.impossible.ble.core

import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

class ScanRecord(
    val deviceName: String?,
    val serviceUuids: List<String>,
    val manufacturerData: Map<Int, ByteArray>,
    val serviceData: Map<String, ByteArray>,
) {
    val bytes: ByteArray? = null
}

class ScanResult(val address: String, val name: String?, val rssi: Int, val record: ScanRecord)

class ScanSubscription(
    val services: List<String>,
    val reportDelayMs: Long,
    val nameFilter: (String?) -> Boolean,
    val onResult: (ScanResult) -> Unit,
    val onBatch: (List<ScanResult>) -> Unit,
) {
    internal val buffer = LinkedHashMap<String, ScanResult>()
    internal var flush: ScheduledFuture<*>? = null
}

class Scanner(private val session: Session, private val identity: Identity) {
    private val subscriptions = mutableListOf<ScanSubscription>()

    init {
        session.discoverListener = ::onDiscover
    }

    fun start(subscription: ScanSubscription) {
        session.scheduler.execute {
            // ponytail: the wire scan uses the first subscriber's services; a later subscriber with other services shares it.
            if (subscriptions.isEmpty()) session.send(Wire.scan(subscription.services))
            subscriptions += subscription
            if (subscription.reportDelayMs > 0) {
                subscription.flush = session.scheduler.scheduleWithFixedDelay(
                    { flush(subscription) },
                    subscription.reportDelayMs,
                    subscription.reportDelayMs,
                    TimeUnit.MILLISECONDS,
                )
            }
        }
    }

    fun onTransportUp() {
        session.scheduler.execute {
            val first = subscriptions.firstOrNull() ?: return@execute
            session.send(Wire.scan(first.services))
        }
    }

    fun stop(subscription: ScanSubscription) {
        session.scheduler.execute {
            subscription.flush?.cancel(false)
            subscriptions -= subscription
            if (subscriptions.isEmpty()) session.send(Wire.stopScan())
        }
    }

    fun toResult(message: DidDiscover): ScanResult {
        val adv = message.adv
        val name = message.name.ifEmpty { adv.localName }
        val record = ScanRecord(
            adv.localName,
            adv.serviceUuids.map(Uuids::expand),
            adv.manufacturerData?.let(::manufacturer).orEmpty(),
            adv.serviceData.mapKeys { Uuids.expand(it.key) },
        )
        return ScanResult(identity.addressFor(message.id), name, message.rssi, record)
    }

    private fun manufacturer(data: ByteArray): Map<Int, ByteArray> {
        if (data.size < COMPANY_ID_BYTES) return emptyMap()
        val companyId = (data[0].toInt() and BYTE_MASK) or ((data[1].toInt() and BYTE_MASK) shl Byte.SIZE_BITS)
        return mapOf(companyId to data.copyOfRange(COMPANY_ID_BYTES, data.size))
    }

    private fun onDiscover(message: DidDiscover) {
        val result = toResult(message)
        subscriptions.filter { it.nameFilter(result.name) }.forEach { sub ->
            if (sub.reportDelayMs > 0) sub.buffer[result.address] = result else session.callbacks.execute { sub.onResult(result) }
        }
    }

    private fun flush(subscription: ScanSubscription) {
        if (subscription.buffer.isEmpty()) return
        val batch = subscription.buffer.values.toList()
        subscription.buffer.clear()
        session.callbacks.execute { subscription.onBatch(batch) }
    }

    private companion object {
        const val COMPANY_ID_BYTES = 2
        const val BYTE_MASK = 0xFF
    }
}
