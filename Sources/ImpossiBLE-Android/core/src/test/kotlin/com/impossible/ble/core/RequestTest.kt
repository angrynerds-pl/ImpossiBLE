package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

class RequestTest {

    private val f = Fixture()
    private val events = java.util.concurrent.CopyOnWriteArrayList<String>()

    @After
    fun tearDown() = f.close()

    private fun manual(queued: Boolean = true, onStart: (Request<String>) -> Unit = {}) =
        f.queue.request("dev", queued) { onStart(it) }

    @Test
    fun `given queued requests, when each completes, then they start in fifo order`() {
        val order = mutableListOf<Int>()
        val reqs = (1..3).map { i -> f.queue.request("dev", true) { order += i } }
        reqs.forEach { it.enqueue() }
        f.drain()
        assertThat(order).containsExactly(1)
        f.scheduler.submit { reqs[0].succeed() }.get()
        f.drain()
        assertThat(order).containsExactly(1, 2).inOrder()
        f.scheduler.submit { reqs[1].succeed() }.get()
        f.drain()
        assertThat(order).containsExactly(1, 2, 3).inOrder()
    }

    @Test
    fun `given an immediate request, then it starts while a queued one is in flight`() {
        val started = mutableListOf<String>()
        f.queue.request("dev", true) { started += "queued" }.enqueue()
        f.queue.request("dev", false) { started += "now" }.enqueue()
        f.drain()
        assertThat(started).containsExactly("queued", "now")
    }

    @Test
    fun `given a request that times out, then fail fires with the timeout reason and then fires after it`() {
        val r = manual().timeout(50)
        r.fail { _, status -> events += "fail$status" }.done { events += "done" }.then { events += "then" }
        r.enqueue()
        f.awaitThat { events.size == 2 }
        assertThat(events).containsExactly("fail${Reason.TIMEOUT}", "then").inOrder()
    }

    @Test
    fun `given a timed out queued request, then the next request starts`() {
        val started = mutableListOf<String>()
        manual().timeout(30).enqueue()
        f.queue.request("dev", true) { started += "next" }.enqueue()
        f.awaitThat { started.isNotEmpty() }
    }

    @Test
    fun `given success, then done fires before then and fail never fires`() {
        val r = manual { it.succeed() }
        r.done { events += "done" }.fail { _, _ -> events += "fail" }.then { events += "then" }.enqueue()
        f.drain()
        assertThat(events).containsExactly("done", "then").inOrder()
    }

    @Test
    fun `given failure, then fail fires before then and done never fires`() {
        val r = manual { it.failWith(Reason.REQUEST_FAILED) }
        r.done { events += "done" }.fail { _, s -> events += "fail$s" }.then { events += "then" }.enqueue()
        f.drain()
        assertThat(events).containsExactly("fail${Reason.REQUEST_FAILED}", "then").inOrder()
    }

    @Test
    fun `given an invalid request, then only the invalid callback fires and the request is finished`() {
        val r = manual { it.invalidate() }
        r.done { events += "done" }.fail { _, _ -> events += "fail" }.then { events += "then" }.invalid { events += "invalid" }
        r.enqueue()
        f.drain()
        assertThat(events).containsExactly("invalid")
        assertThat(r.isFinished).isTrue()
    }

    @Test
    fun `given an invalid queued request, then the queue moves on`() {
        val started = mutableListOf<String>()
        manual { it.invalidate() }.enqueue()
        f.queue.request("dev", true) { started += "next" }.enqueue()
        f.drain()
        assertThat(started).containsExactly("next")
    }

    @Test
    fun `given a request finishing twice, then callbacks fire once`() {
        val r = manual { it.succeed(); it.failWith(Reason.TIMEOUT) }
        r.done { events += "done" }.fail { _, _ -> events += "fail" }.enqueue()
        f.drain()
        assertThat(events).containsExactly("done")
    }

    @Test
    fun `given a throwing done callback, then then still fires`() {
        val r = manual { it.succeed() }
        r.done { error("boom") }.then { events += "then" }.enqueue()
        f.drain()
        assertThat(events).containsExactly("then")
    }

    @Test
    fun `given a callback executor on another thread, then callbacks run there`() {
        val thread = AtomicReference<Thread>()
        val ex = java.util.concurrent.Executors.newSingleThreadExecutor()
        val queue = RequestQueue(f.scheduler, ex)
        val latch = CountDownLatch(1)
        queue.request("dev", true) { it.succeed() }.done { thread.set(Thread.currentThread()); latch.countDown() }.enqueue()
        assertThat(latch.await(Fixture.WAIT_S, TimeUnit.SECONDS)).isTrue()
        assertThat(thread.get()).isNotEqualTo(Thread.currentThread())
        ex.shutdownNow()
    }

    @Test
    fun `given await and success, then it returns`() {
        manual { it.succeed() }.await()
    }

    @Test
    fun `given await, then it replaces earlier done fail and invalid callbacks but keeps then`() {
        val r = manual { it.succeed() }
        r.done { events += "done" }.fail { _, _ -> events += "fail" }.invalid { events += "invalid" }.then { events += "then" }
        r.await()
        f.awaitThat { events.contains("then") }
        assertThat(events).containsExactly("then")
    }

    @Test
    fun `given await and each status, then the matching exception is thrown`() {
        assertThrows(DeviceDisconnectedException::class.java) { manual { it.failWith(Reason.DEVICE_DISCONNECTED) }.await() }
        assertThrows(BluetoothDisabledException::class.java) { manual { it.failWith(Reason.BLUETOOTH_DISABLED) }.await() }
        assertThrows(InvalidRequestException::class.java) { manual { it.invalidate() }.await() }
        val e = assertThrows(RequestFailedException::class.java) { manual { it.failWith(Reason.NULL_ATTRIBUTE) }.await() }
        assertThat(e.status).isEqualTo(Reason.NULL_ATTRIBUTE)
        val t = assertThrows(RequestFailedException::class.java) { manual { }.timeout(30).await() }
        assertThat(t.status).isEqualTo(Reason.TIMEOUT)
    }

    @Test
    fun `given the invalid sentinel, then it is the nordic internal value`() {
        assertThat(Reason.REQUEST_INVALID).isEqualTo(-1000000)
        assertThat(Reason.DEVICE_DISCONNECTED).isEqualTo(-1)
        assertThat(Reason.DEVICE_NOT_SUPPORTED).isEqualTo(-2)
        assertThat(Reason.NULL_ATTRIBUTE).isEqualTo(-3)
        assertThat(Reason.REQUEST_FAILED).isEqualTo(-4)
        assertThat(Reason.TIMEOUT).isEqualTo(-5)
        assertThat(Reason.VALIDATION).isEqualTo(-6)
        assertThat(Reason.CANCELLED).isEqualTo(-7)
        assertThat(Reason.BLUETOOTH_DISABLED).isEqualTo(-100)
        assertThat(Reason.GATT_ERROR).isEqualTo(133)
    }

    @Test
    fun `given abort, then the in-flight request fails as disconnected and queued requests are dropped silently`() {
        val inFlight = manual { }
        val queued = manual { events += "queued started" }
        inFlight.fail { _, s -> events += "fail$s" }
        queued.fail { _, s -> events += "queuedfail$s" }.done { events += "queueddone" }.then { events += "queuedthen" }
        inFlight.enqueue()
        queued.enqueue()
        f.drain()
        f.queue.abort()
        f.drain()
        assertThat(events).containsExactly("fail${Reason.DEVICE_DISCONNECTED}")
        assertThat(queued.isFinished).isFalse()
    }

    @Test
    fun `given a queued write dropped at disconnect, when awaited, then await never returns`() {
        manual { }.enqueue()
        val write = manual { }
        val returned = CountDownLatch(1)
        val t = Thread {
            try {
                write.await()
            } catch (ignored: Exception) {
                returned.countDown()
            }
            returned.countDown()
        }
        t.isDaemon = true
        t.start()
        f.drain()
        f.queue.abort()
        f.drain()
        assertThat(returned.await(300, TimeUnit.MILLISECONDS)).isFalse()
        t.interrupt()
    }

    @Test
    fun `given an immediate request in flight, when the queue aborts, then it is not touched`() {
        val r = f.queue.request("dev", false) { }
        r.done { events += "done" }.fail { _, _ -> events += "fail" }.enqueue()
        f.drain()
        f.queue.abort()
        f.drain()
        assertThat(events).isEmpty()
    }

    @Test
    fun `given onFinished, then it runs once when the request finishes`() {
        val r = manual { it.succeed() }
        r.onFinished { events += "cleanup" }
        r.enqueue()
        f.drain()
        assertThat(events).containsExactly("cleanup")
    }
}
