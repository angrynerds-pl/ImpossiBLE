package com.impossible.ble.shim

import com.google.common.truth.Truth.assertThat
import com.impossible.ble.BleDevice
import com.impossible.ble.core.Reason
import com.impossible.ble.core.RequestQueue
import no.nordicsemi.android.ble.Request
import no.nordicsemi.android.ble.WriteRequest
import no.nordicsemi.android.ble.callback.FailCallback
import no.nordicsemi.android.ble.exception.BluetoothDisabledException
import no.nordicsemi.android.ble.exception.DeviceDisconnectedException
import no.nordicsemi.android.ble.exception.InvalidRequestException
import no.nordicsemi.android.ble.exception.RequestFailedException
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executor
import java.util.concurrent.Executors

class RequestTest {

    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private val queue = RequestQueue(scheduler, Executor { it.run() })
    private val device = BleDevice("02:00:00:00:00:01", "PM5")
    private val events = CopyOnWriteArrayList<String>()

    @After
    fun tearDown() {
        scheduler.shutdownNow()
        MainThread.isMain = MainThread.default
    }

    private fun request(operation: (com.impossible.ble.core.Request<BleDevice>) -> Unit): WriteRequest =
        WriteRequest("write") { queue.request(device, true, operation) }

    private fun Request.record() = done { events += "done" }.fail { _, status -> events += "fail $status" }
        .invalid { events += "invalid" }.then { events += "then" }

    @Test
    fun `given the main thread, when await is called, then it throws the nordic message`() {
        MainThread.isMain = { true }
        val thrown = assertThrows(IllegalStateException::class.java) { request { it.succeed() }.await() }
        assertThat(thrown).hasMessageThat().isEqualTo("Cannot execute synchronous operation from the UI thread.")
    }

    @Test
    fun `given a successful operation, when await is called off the main thread, then it returns`() {
        MainThread.isMain = { false }
        request { it.succeed() }.await()
    }

    @Test
    fun `given failure statuses, when await is called, then nordic exceptions are thrown`() {
        MainThread.isMain = { false }
        assertThrows(DeviceDisconnectedException::class.java) { request { it.failWith(Reason.DEVICE_DISCONNECTED) }.await() }
        assertThrows(BluetoothDisabledException::class.java) { request { it.failWith(Reason.BLUETOOTH_DISABLED) }.await() }
        assertThrows(InvalidRequestException::class.java) { request { it.invalidate() }.await() }
        val failed = request { it.failWith(Reason.GATT_ERROR) }
        val thrown = assertThrows(RequestFailedException::class.java) { failed.await() }
        assertThat(thrown.status).isEqualTo(Reason.GATT_ERROR)
        assertThat(thrown.request).isSameInstanceAs(failed)
    }

    @Test
    fun `given user callbacks, when await is called, then done fail and invalid are overwritten and then survives`() {
        MainThread.isMain = { false }
        val r = request { it.succeed() }
        r.record()
        r.await()
        assertThat(events).containsExactly("then")
    }

    @Test
    fun `given a failing request, when enqueued, then fail gets device and status then fires after it`() {
        val seen = CopyOnWriteArrayList<Pair<BleDevice, Int>>()
        request { it.failWith(Reason.TIMEOUT) }.record().fail(FailCallback { d, s -> seen += d to s; events += "fail" }).enqueue()
        waitFor { events.size == 2 }
        assertThat(events).containsExactly("fail", "then").inOrder()
        assertThat(seen.single()).isEqualTo(device to FailCallback.REASON_TIMEOUT)
    }

    @Test
    fun `given an invalid request, when enqueued, then only the invalid callback fires`() {
        request { it.invalidate() }.record().enqueue()
        waitFor { events.isNotEmpty() }
        Thread.sleep(SETTLE_MS)
        assertThat(events).containsExactly("invalid")
    }

    @Test
    fun `given a queued request dropped by an abort, when awaited, then it throws device disconnected and fail fires`() {
        MainThread.isMain = { false }
        request { }.enqueue()
        val queued = request { }.fail { _, status -> events += "fail $status" }
        val thrown = java.util.concurrent.atomic.AtomicReference<Throwable>()
        val t = Thread {
            try {
                queued.await()
            } catch (e: DeviceDisconnectedException) {
                thrown.set(e)
            }
        }
        t.start()
        waitFor { queue.queuedCount() == 2 }
        queue.abort()
        t.join(WAIT_NS / 1_000_000)
        assertThat(thrown.get()).isInstanceOf(DeviceDisconnectedException::class.java)
    }

    @Test
    fun `given a request that never completes, when awaited past the ceiling, then it throws a timeout failure`() {
        MainThread.isMain = { false }
        val bounded = RequestQueue(scheduler, Executor { it.run() }, awaitCeilingMs = 100)
        val unbounded = WriteRequest("write") { bounded.request(device, false) { } }
        unbounded.timeoutMillis = 0
        val thrown = assertThrows(RequestFailedException::class.java) { unbounded.await() }
        assertThat(thrown.status).isEqualTo(Reason.TIMEOUT)
    }

    @Test
    fun `given no operation behind the request, when enqueued, then it names the unsupported method`() {
        val thrown = assertThrows(UnsupportedOperationException::class.java) { WriteRequest("write", null).enqueue() }
        assertThat(thrown).hasMessageThat().isEqualTo("ImpossiBLE shim: write")
    }

    private fun waitFor(condition: () -> Boolean) {
        val deadline = System.nanoTime() + WAIT_NS
        while (!condition() && System.nanoTime() < deadline) Thread.sleep(POLL_MS)
        assertThat(condition()).isTrue()
    }

    private companion object {
        const val WAIT_NS = 5_000_000_000L
        const val POLL_MS = 5L
        const val SETTLE_MS = 50L
    }
}
