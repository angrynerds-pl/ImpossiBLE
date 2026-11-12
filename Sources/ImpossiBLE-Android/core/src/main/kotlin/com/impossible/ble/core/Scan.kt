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
    val accept: (ScanResult) -> Boolean,
    val onResult: (ScanResult) -> Unit,
    val onBatch: (List<ScanResult>) -> Unit,
) {
    internal val buffer = LinkedHashMap<String, ScanResult>()
    internal var flush: ScheduledFuture<*>? = null
}

class Scanner(private val session: Session, private val identity: Identity) {
    private val subscriptions = mutableListOf<ScanSubscription>()
    private var wireServices: List<String>? = null

    init {
        session.discoverListener = ::onDiscover
    }

    fun start(subscription: ScanSubscription) {
        session.scheduler.execute {
            subscriptions += subscription
            syncWireScan()
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
            wireServices = null
            syncWireScan()
        }
    }

    fun stop(subscription: ScanSubscription) {
        session.scheduler.execute {
            subscription.flush?.cancel(false)
            subscriptions -= subscription
            syncWireScan()
        }
    }

    // The provider scan covers every subscription: unfiltered as soon as one is, else the union of services.
    private fun syncWireScan() {
        val wanted = when {
            subscriptions.isEmpty() -> null
            subscriptions.any { it.services.isEmpty() } -> emptyList()
            else -> subscriptions.flatMap { it.services }.distinct()
        }
        if (wanted == wireServices) return
        wireServices = wanted
        session.send(if (wanted == null) Wire.stopScan() else Wire.scan(wanted))
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
        subscriptions.filter { matches(it, result) }.forEach { sub ->
            if (sub.reportDelayMs > 0) sub.buffer[result.address] = result else session.callbacks.execute { sub.onResult(result) }
        }
    }

    private fun matches(sub: ScanSubscription, result: ScanResult): Boolean {
        // A result that advertises no service list cannot be told apart (CoreBluetooth may match on the overflow area), so it passes.
        val serviceOk = sub.services.isEmpty() || result.record.serviceUuids.isEmpty() ||
            sub.services.any { wanted -> result.record.serviceUuids.any { it.equals(Uuids.expand(wanted), ignoreCase = true) } }
        return serviceOk && sub.accept(result)
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
