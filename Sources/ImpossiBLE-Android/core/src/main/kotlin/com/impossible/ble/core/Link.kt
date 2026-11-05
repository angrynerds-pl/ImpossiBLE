package com.impossible.ble.core

import java.util.concurrent.TimeUnit

interface LinkHooks {
    fun onConnecting()
    fun onConnected()
    fun onFailedToConnect(reason: Int)
    fun onDisconnecting()
    fun onDisconnected(reason: Int)
    fun onReady()
    fun requiredSupported(services: List<DiscoveredService>): Boolean
    fun optionalSupported()
    fun initialize()
    fun onManagerReady()
    fun onServicesInvalidated()
}

object ObserverReason {
    const val UNKNOWN = -1
    const val TERMINATE_LOCAL_HOST = 1
    const val TERMINATE_PEER_USER = 2
    const val LINK_LOSS = 3
    const val NOT_SUPPORTED = 4
    const val CANCELLED = 5
    const val TIMEOUT = 10
}

private enum class LinkState { Idle, Connecting, Initializing, Ready, Disconnecting }

class Link<D>(
    private val session: Session,
    private val id: String,
    val device: D,
    private val hooks: LinkHooks,
    private val retryDelayMs: Long = 500,
    private val stepTimeoutMs: Long = 5_000,
) : Peer {
    val peripheralId: String get() = id
    private val gatt = Gatt(session, id, device)
    private val queue = session.queueFor(id)
    private val discovery = Discovery(session, id, device, stepTimeoutMs)
    private val pendingDisconnects = mutableListOf<Request<D>>()
    private var state = LinkState.Idle
    private var connecting: Request<D>? = null
    private var localDisconnect = false

    @Volatile
    var services: List<DiscoveredService> = emptyList()
        private set

    @Volatile
    private var mirror = LinkState.Idle

    val isConnected: Boolean get() = mirror == LinkState.Initializing || mirror == LinkState.Ready
    val isReady: Boolean get() = mirror == LinkState.Ready

    init {
        session.register(id, this)
    }

    fun characteristicId(serviceUuid: String, characteristicUuid: String): String? =
        services.firstOrNull { it.uuid == serviceUuid }?.characteristics?.firstOrNull { it.uuid == characteristicUuid }?.id

    fun read(characteristicId: String) = gatt.read(characteristicId)

    fun write(characteristicId: String, data: ByteArray, withResponse: Boolean) = gatt.write(characteristicId, data, withResponse)

    fun writeSplit(characteristicId: String, data: ByteArray, withResponse: Boolean) = gatt.writeSplit(characteristicId, data, withResponse)

    fun setNotify(characteristicId: String, enabled: Boolean) = gatt.setNotify(characteristicId, enabled)

    fun local(queued: Boolean = true, operation: (Request<D>) -> Unit): Request<D> = queue.request(device, queued, operation)

    fun connect(): Request<D> = queue.request(device, false) { r ->
        when (state) {
            LinkState.Idle -> {
                enter(LinkState.Connecting)
                connecting = r
                r.onFinished { timedOut(r) }
                post { hooks.onConnecting() }
                attempt(r, r.retryCount)
            }
            LinkState.Ready -> r.succeed()
            else -> r.failWith(Reason.REQUEST_FAILED)
        }
    }.timeout(CONNECT_TIMEOUT_MS)

    fun disconnect(): Request<D> = queue.request(device, false) { r ->
        when (state) {
            LinkState.Idle -> r.succeed()
            LinkState.Connecting -> {
                session.send(Wire.cancel(id))
                enter(LinkState.Idle)
                connecting?.failWith(Reason.CANCELLED)
                post { hooks.onFailedToConnect(ObserverReason.CANCELLED) }
                r.succeed()
            }
            else -> {
                localDisconnect = true
                r.onFinished { disconnectTimedOut(r) }
                enter(LinkState.Disconnecting)
                pendingDisconnects += r
                post { hooks.onDisconnecting() }
                session.send(Wire.cancel(id))
            }
        }
    }

    override fun onDisconnected(error: String, transportLost: Boolean) {
        if (state == LinkState.Idle || state == LinkState.Connecting) return
        val reason = when {
            localDisconnect -> ObserverReason.TERMINATE_LOCAL_HOST
            transportLost || error.isNotEmpty() -> ObserverReason.LINK_LOSS
            else -> ObserverReason.TERMINATE_PEER_USER
        }
        tearDown(reason)
        connecting?.failWith(Reason.DEVICE_DISCONNECTED)
        pendingDisconnects.toList().forEach { it.succeed() }
        pendingDisconnects.clear()
    }

    private fun disconnectTimedOut(r: Request<D>) {
        if (r.failureStatus != Reason.TIMEOUT || state != LinkState.Disconnecting) return
        queue.abortNow()
        onDisconnected("", false)
    }

    private fun attempt(r: Request<D>, remaining: Int) {
        val token = session.correlator.expect(Key(Kind.Connect, id)) { reply ->
            if (reply is DidConnect) connected(r, reply) else connectFailed(r, remaining)
        }
        r.onFinished { token.cancel() }
        session.send(Wire.connect(id))
    }

    private fun connectFailed(r: Request<D>, remaining: Int) {
        if (state != LinkState.Connecting || r.isFinished) return
        if (remaining > 0) {
            session.scheduler.schedule(
                { if (state == LinkState.Connecting && !r.isFinished) attempt(r, remaining - 1) },
                r.retryDelayMs,
                TimeUnit.MILLISECONDS,
            )
            return
        }
        enter(LinkState.Idle)
        post { hooks.onFailedToConnect(ObserverReason.UNKNOWN) }
        r.failWith(Reason.DEVICE_DISCONNECTED)
    }

    private fun timedOut(r: Request<D>) {
        if (r.failureStatus != Reason.TIMEOUT || state != LinkState.Connecting) return
        session.send(Wire.cancel(id))
        enter(LinkState.Idle)
        post { hooks.onFailedToConnect(ObserverReason.TIMEOUT) }
    }

    private fun connected(r: Request<D>, reply: DidConnect) {
        if (state != LinkState.Connecting || r.isFinished) return
        session.recordLimits(reply)
        r.clearTimeout()
        enter(LinkState.Initializing)
        post { hooks.onConnected() }
        discovery.run({ found -> discovered(r, found) }, { status -> initFailed(r, status) })
    }

    private fun discovered(r: Request<D>, found: List<DiscoveredService>) {
        if (state != LinkState.Initializing) return
        services = found
        queue.beginInit()
        session.callbacks.execute {
            val supported = try {
                hooks.requiredSupported(found).also { ok ->
                    if (ok) {
                        hooks.optionalSupported()
                        queue.initCapture = true
                        try {
                            hooks.initialize()
                        } finally {
                            queue.initCapture = false
                        }
                    }
                }
            } catch (ignored: Exception) {
                null
            }
            session.scheduler.execute { afterHooks(r, supported) }
        }
    }

    private fun afterHooks(r: Request<D>, supported: Boolean?) {
        if (state != LinkState.Initializing) return
        when (supported) {
            true -> queue.endInit { ready(r) }
            false -> abandon(r, Reason.DEVICE_NOT_SUPPORTED, ObserverReason.NOT_SUPPORTED, failedToConnect = true)
            null -> initFailed(r, Reason.REQUEST_FAILED)
        }
    }

    private fun ready(r: Request<D>) {
        if (state != LinkState.Initializing) return
        enter(LinkState.Ready)
        post {
            hooks.onManagerReady()
            hooks.onReady()
        }
        connecting = null
        r.succeed()
    }

    private fun initFailed(r: Request<D>, status: Int) {
        if (state != LinkState.Initializing) return
        abandon(r, status, ObserverReason.TERMINATE_LOCAL_HOST, failedToConnect = false)
    }

    private fun abandon(r: Request<D>, status: Int, reason: Int, failedToConnect: Boolean) {
        session.send(Wire.cancel(id))
        queue.abortNow()
        if (failedToConnect) {
            enter(LinkState.Idle)
            post { hooks.onFailedToConnect(reason) }
        } else {
            tearDown(reason)
        }
        r.failWith(status)
    }

    private fun tearDown(reason: Int) {
        val hadServices = services.isNotEmpty()
        enter(LinkState.Idle)
        localDisconnect = false
        connecting = connecting?.takeIf { !it.isFinished }
        services = emptyList()
        post {
            hooks.onDisconnected(reason)
            if (hadServices) hooks.onServicesInvalidated()
        }
    }

    private fun enter(next: LinkState) {
        state = next
        mirror = next
    }

    private fun post(block: () -> Unit) = session.callbacks.execute(block)

    private companion object {
        const val CONNECT_TIMEOUT_MS = 10_000L
    }
}
