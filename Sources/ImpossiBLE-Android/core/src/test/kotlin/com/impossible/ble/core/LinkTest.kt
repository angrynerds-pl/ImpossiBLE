package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

class LinkTest {

    private val f = Fixture()
    private val events = CopyOnWriteArrayList<String>()
    private var supported = true
    private var initialize: (Link<String>) -> Unit = {}

    private val hooks = object : LinkHooks {
        override fun onConnecting() { events += "connecting" }
        override fun onConnected() { events += "connected" }
        override fun onFailedToConnect(reason: Int) { events += "failed $reason" }
        override fun onDisconnecting() { events += "disconnecting" }
        override fun onDisconnected(reason: Int) { events += "disconnected $reason" }
        override fun onReady() { events += "observerReady" }
        override fun requiredSupported(services: List<DiscoveredService>): Boolean {
            events += "required ${services.joinToString { it.uuid.take(4) + ":" + it.characteristics.size }}"
            return supported
        }
        override fun optionalSupported() { events += "optional" }
        override fun initialize() { events += "initialize"; initialize(link) }
        override fun onManagerReady() { events += "managerReady" }
        override fun onServicesInvalidated() { events += "invalidated" }
    }
    private val link: Link<String> = Link(f.session, "p", "dev", hooks, retryDelayMs = 10)

    @After
    fun tearDown() = f.close()

    private fun sentTypes() = f.sent.map { Regex("\"type\":\"(\\w+)\"").find(it)?.groupValues?.get(1) }

    private fun connectAndDiscover() {
        f.incoming("""{"type":"didConnect","id":"p","maxWriteWithResponse":512,"maxWriteWithoutResponse":182}""")
        f.awaitThat { "discoverServices" in sentTypes() }
        f.incoming("""{"type":"didDiscoverServices","id":"p","services":[{"id":"s1","uuid":"CE060020-43E5-11E4-916C-0800200C9A66","primary":true}],"error":""}""")
        f.awaitThat { "discoverCharacteristics" in sentTypes() }
        f.incoming(
            """{"type":"didDiscoverCharacteristics","id":"p","serviceId":"s1","characteristics":[{"id":"c1","uuid":"CE060021-43E5-11E4-916C-0800200C9A66","properties":8},""" +
                """{"id":"c2","uuid":"CE060022-43E5-11E4-916C-0800200C9A66","properties":16}],"error":""}""",
        )
    }

    @Test
    fun `given a connect, then the nordic order holds and connect completes only after init drained`() {
        initialize = { l ->
            l.setNotify("c2", true).done { events += "notifyDone" }.enqueue()
            l.read("c1").done { events += "readDone" }.enqueue()
        }
        link.connect().done { events += "connectDone" }.enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "setNotify" in sentTypes() }
        assertThat(sentTypes()).doesNotContain("read")
        f.incoming("""{"type":"didUpdateNotification","id":"p","characteristicId":"c2","enabled":true,"error":""}""")
        f.awaitThat { "read" in sentTypes() }
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c1","value":"","error":"","isNotification":false}""")
        f.awaitThat { "connectDone" in events }
        assertThat(events).containsExactly(
            "connecting", "connected", "required ce06:2", "optional", "initialize", "notifyDone", "readDone",
            "managerReady", "observerReady", "connectDone",
        ).inOrder()
    }

    @Test
    fun `given a task request enqueued during init, then it waits for the init queue and the ready callbacks`() {
        initialize = { l -> l.read("c1").done { events += "initRead" }.enqueue() }
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "read" in sentTypes() }
        link.setNotify("c2", true).done { events += "taskNotify" }.enqueue()
        f.drain()
        assertThat(sentTypes()).doesNotContain("setNotify")
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c1","value":"","error":"","isNotification":false}""")
        f.awaitThat { "setNotify" in sentTypes() }
        assertThat(events).containsAtLeast("initRead", "managerReady", "observerReady").inOrder()
    }

    @Test
    fun `given an unsupported device, then connect fails with not supported and the peripheral is cancelled`() {
        supported = false
        var status = 0
        link.connect().fail { _, s -> status = s }.enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { status != 0 }
        assertThat(status).isEqualTo(Reason.DEVICE_NOT_SUPPORTED)
        assertThat(events).contains("failed 4")
        assertThat(events).doesNotContain("initialize")
        assertThat(sentTypes()).contains("cancel")
    }

    @Test
    fun `given didFailConnect without retries, then the observer sees failed to connect and connect fails with disconnected`() {
        var status = 0
        link.connect().fail { _, s -> status = s }.enqueue()
        f.awaitThat { "connect" in sentTypes() }
        f.incoming("""{"type":"didFailConnect","id":"p","error":"nope"}""")
        f.awaitThat { status != 0 }
        assertThat(status).isEqualTo(Reason.DEVICE_DISCONNECTED)
        assertThat(events).containsExactly("connecting", "failed -1").inOrder()
    }

    @Test
    fun `given retries, when the first attempt fails, then a second connect is sent before any observer failure`() {
        link.connect().retry(2, 10).enqueue()
        f.awaitThat { "connect" in sentTypes() }
        f.incoming("""{"type":"didFailConnect","id":"p","error":"nope"}""")
        f.awaitThat { sentTypes().count { it == "connect" } == 2 }
        assertThat(events).containsExactly("connecting")
        f.incoming("""{"type":"didConnect","id":"p"}""")
        f.awaitThat { "connected" in events }
    }

    @Test
    fun `given a connect that never answers, then it times out`() {
        var status = 0
        link.connect().timeout(50).fail { _, s -> status = s }.enqueue()
        f.awaitThat { status != 0 }
        assertThat(status).isEqualTo(Reason.TIMEOUT)
        assertThat(events).contains("failed 10")
    }

    @Test
    fun `given a discovery that never answers, then connect fails with a timeout and the peripheral is cancelled`() {
        var status = 0
        val l = Link(f.session, "p", "dev", hooks, retryDelayMs = 10, stepTimeoutMs = 50)
        l.connect().fail { _, s -> status = s }.enqueue()
        f.awaitThat { "connect" in sentTypes() }
        f.incoming("""{"type":"didConnect","id":"p"}""")
        f.awaitThat { status != 0 }
        assertThat(status).isEqualTo(Reason.TIMEOUT)
        assertThat(sentTypes()).contains("cancel")
        assertThat(events).contains("disconnected 1")
    }

    @Test
    fun `given a ready link, when the provider disconnects, then queued requests fail and observer and invalidation follow`() {
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        var status = 0
        link.read("c1").fail { _, s -> status = s }.enqueue()
        f.awaitThat { "read" in sentTypes() }
        f.incoming("""{"type":"didDisconnect","id":"p","error":""}""")
        f.awaitThat { events.any { it.startsWith("disconnected") } }
        assertThat(status).isEqualTo(Reason.DEVICE_DISCONNECTED)
        assertThat(events.takeLast(2)).containsExactly("disconnected 2", "invalidated").inOrder()
    }

    @Test
    fun `given a ready link, when the transport drops, then the reason is link loss`() {
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        f.session.onTransportLost()
        f.awaitThat { events.any { it.startsWith("disconnected") } }
        assertThat(events).contains("disconnected 3")
    }

    @Test
    fun `given a ready link, when disconnect is requested, then cancel is sent and the request completes after the observer`() {
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        link.disconnect().done { events += "disconnectDone" }.enqueue()
        f.awaitThat { "cancel" in sentTypes() }
        assertThat(events.last()).isEqualTo("disconnecting")
        f.incoming("""{"type":"didDisconnect","id":"p","error":""}""")
        f.awaitThat { "disconnectDone" in events }
        assertThat(events.takeLast(3)).containsExactly("disconnected 1", "invalidated", "disconnectDone").inOrder()
    }

    @Test
    fun `given a disconnect that times out, then the link tears down locally and does not stay disconnecting`() {
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        link.disconnect().timeout(50).fail { _, s -> events += "disconnectFail $s" }.enqueue()
        f.awaitThat { "disconnected 1" in events }
        assertThat(events).contains("disconnectFail ${Reason.TIMEOUT}")
        assertThat(link.isConnected).isFalse()
        sentTypes().let { sent -> assertThat(sent.count { it == "cancel" }).isEqualTo(1) }
        f.sent.clear()
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
    }

    @Test
    fun `given a discovery failure from an ended connection, then it does not cancel the replacement connection`() {
        val deferred = java.util.concurrent.ConcurrentLinkedQueue<Runnable>()
        val g = Fixture { deferred.add(it) }
        try {
            val l = Link(g.session, "p", "dev", hooks, retryDelayMs = 10)
            val types = { g.sent.map { Regex("\"type\":\"(\\w+)\"").find(it)?.groupValues?.get(1) } }
            l.connect().enqueue()
            g.drain()
            g.incoming("""{"type":"didConnect","id":"p","maxWriteWithResponse":512,"maxWriteWithoutResponse":182}""")
            g.incoming("""{"type":"didDisconnect","id":"p","error":""}""")
            l.connect().enqueue()
            g.drain()
            g.incoming("""{"type":"didConnect","id":"p","maxWriteWithResponse":512,"maxWriteWithoutResponse":182}""")
            g.awaitThat { types().count { it == "discoverServices" } == 2 }
            while (deferred.isNotEmpty()) deferred.poll().run()
            g.drain()
            assertThat(types()).doesNotContain("cancel")
            assertThat(l.isConnected).isTrue()
        } finally {
            g.close()
        }
    }

    @Test
    fun `given a session shutdown, then queued requests fail and the scheduler stops`() {
        val status = java.util.concurrent.atomic.AtomicInteger()
        val queue = f.session.queueFor("x")
        queue.request("dev", true) { }.enqueue()
        queue.request("dev", true) { }.fail { _, s -> status.set(s) }.enqueue()
        f.drain()
        f.session.shutdown()
        f.awaitThat { f.scheduler.isTerminated }
        assertThat(status.get()).isEqualTo(Reason.DEVICE_DISCONNECTED)
    }

    @Test
    fun `given an idle link, when disconnect is requested, then it succeeds without wire traffic`() {
        var done = false
        link.disconnect().done { done = true }.enqueue()
        f.awaitThat { done }
        assertThat(f.sent).isEmpty()
    }

    @Test
    fun `given an init step that times out, then init continues and connect still completes`() {
        initialize = { l -> l.read("c1").timeout(30).fail { _, s -> events += "initFail $s" }.enqueue() }
        link.connect().done { events += "connectDone" }.enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "connectDone" in events }
        assertThat(events).contains("initFail ${Reason.TIMEOUT}")
    }

    @Test
    fun `given notifications after ready, then they reach the registered callback`() {
        val got = CopyOnWriteArrayList<List<Byte>>()
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        f.session.setNotificationCallback("p", "c2") { got += it.toList() }
        f.drain()
        f.incoming("""{"type":"didUpdateValue","id":"p","characteristicId":"c2","value":"AQI=","error":"","isNotification":true}""")
        assertThat(got).containsExactly(listOf<Byte>(1, 2))
    }

    @Test
    fun `given discovered services, then characteristic lookup by service and uuid yields the wire id`() {
        link.connect().enqueue()
        f.awaitThat { "connect" in sentTypes() }
        connectAndDiscover()
        f.awaitThat { "observerReady" in events }
        assertThat(link.characteristicId("ce060020-43e5-11e4-916c-0800200c9a66", "ce060022-43e5-11e4-916c-0800200c9a66")).isEqualTo("c2")
        assertThat(link.characteristicId("ce060020-43e5-11e4-916c-0800200c9a66", "ffff")).isNull()
    }
}
