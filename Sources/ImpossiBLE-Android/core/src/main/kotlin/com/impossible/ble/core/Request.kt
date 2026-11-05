package com.impossible.ble.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

object Reason {
    const val DEVICE_DISCONNECTED = -1
    const val DEVICE_NOT_SUPPORTED = -2
    const val NULL_ATTRIBUTE = -3
    const val REQUEST_FAILED = -4
    const val TIMEOUT = -5
    const val VALIDATION = -6
    const val CANCELLED = -7
    const val BLUETOOTH_DISABLED = -100
    const val REQUEST_INVALID = -1000000
    const val GATT_ERROR = 133
}

class RequestFailedException(val status: Int) : Exception("request failed with status $status")
class DeviceDisconnectedException : Exception("device disconnected")
class BluetoothDisabledException : Exception("bluetooth disabled")
class InvalidRequestException : Exception("invalid request")

class Request<D> internal constructor(
    val device: D,
    private val queue: RequestQueue,
    private val queued: Boolean,
    private val operation: (Request<D>) -> Unit,
) {
    var value: ByteArray? = null

    @Volatile
    var isFinished = false
        private set

    private var doneCallback: ((D) -> Unit)? = null
    private var failCallback: ((D, Int) -> Unit)? = null
    private var invalidCallback: (() -> Unit)? = null
    private var thenCallback: ((D) -> Unit)? = null
    private var timeoutMs = DEFAULT_TIMEOUT_MS
    internal var forInit = false
    internal var retryCount = 0
        private set
    internal var retryDelayMs = 0L
        private set
    internal var failureStatus: Int? = null
        private set
    private var timer: ScheduledFuture<*>? = null
    private val cleanups = mutableListOf<() -> Unit>()

    fun done(callback: (D) -> Unit) = apply { doneCallback = callback }

    fun fail(callback: (D, Int) -> Unit) = apply { failCallback = callback }

    fun invalid(callback: () -> Unit) = apply { invalidCallback = callback }

    fun then(callback: (D) -> Unit) = apply { thenCallback = callback }

    fun timeout(millis: Long) = apply { timeoutMs = millis }

    fun retry(count: Int, delayMs: Long) = apply {
        retryCount = count
        retryDelayMs = delayMs
    }

    fun clearTimeout() {
        timer?.cancel(false)
    }

    fun enqueue() = apply {
        forInit = queue.initCapture
        queue.submit(this, queued)
    }

    @Throws(
        RequestFailedException::class,
        DeviceDisconnectedException::class,
        BluetoothDisabledException::class,
        InvalidRequestException::class,
    )
    fun await() {
        val latch = CountDownLatch(1)
        val status = AtomicInteger()
        doneCallback = { latch.countDown() }
        failCallback = { _, s -> status.set(s); latch.countDown() }
        invalidCallback = { status.set(Reason.REQUEST_INVALID); latch.countDown() }
        enqueue()
        latch.await()
        when (val s = status.get()) {
            0 -> Unit
            Reason.DEVICE_DISCONNECTED -> throw DeviceDisconnectedException()
            Reason.BLUETOOTH_DISABLED -> throw BluetoothDisabledException()
            Reason.REQUEST_INVALID -> throw InvalidRequestException()
            else -> throw RequestFailedException(s)
        }
    }

    internal fun start() {
        if (timeoutMs > 0) timer = queue.scheduler.schedule({ failWith(Reason.TIMEOUT) }, timeoutMs, TimeUnit.MILLISECONDS)
        operation(this)
    }

    fun onFinished(cleanup: () -> Unit) {
        cleanups += cleanup
    }

    fun succeed() = finish { device ->
        safely { doneCallback?.invoke(device) }
        safely { thenCallback?.invoke(device) }
    }

    fun failWith(status: Int) = finish(status) { device ->
        safely { failCallback?.invoke(device, status) }
        safely { thenCallback?.invoke(device) }
    }

    fun invalidate() = finish { safely { invalidCallback?.invoke() } }

    private fun finish(status: Int? = null, notify: (D) -> Unit) {
        if (isFinished) return
        isFinished = true
        failureStatus = status
        timer?.cancel(false)
        cleanups.forEach { it() }
        queue.callbacks.execute { notify(device) }
        if (queued) queue.finished(this)
    }

    private fun safely(block: () -> Unit) {
        try {
            block()
        } catch (ignored: Exception) {
            return
        }
    }

    private companion object {
        const val DEFAULT_TIMEOUT_MS = 5_000L
    }
}

class RequestQueue(internal val scheduler: ScheduledExecutorService, internal val callbacks: Executor) {
    private val waiting = ArrayDeque<Request<*>>()
    private val initWaiting = ArrayDeque<Request<*>>()
    private var current: Request<*>? = null
    private var holdTasks = false
    private var drained: (() -> Unit)? = null

    @Volatile
    var initCapture = false

    fun <D> request(device: D, queued: Boolean, operation: (Request<D>) -> Unit) = Request(device, this, queued, operation)

    internal fun submit(request: Request<*>, queued: Boolean) {
        scheduler.execute {
            if (queued) {
                (if (request.forInit) initWaiting else waiting).addLast(request)
                pump()
            } else {
                request.start()
            }
        }
    }

    internal fun finished(request: Request<*>) {
        if (current === request) {
            current = null
            pump()
        }
    }

    fun abort() {
        scheduler.execute { abortNow() }
    }

    internal fun beginInit() {
        holdTasks = true
    }

    internal fun endInit(onDrained: () -> Unit) {
        drained = onDrained
        pump()
    }

    internal fun abortNow() {
        val inFlight = current
        waiting.clear()
        initWaiting.clear()
        holdTasks = false
        drained = null
        inFlight?.failWith(Reason.DEVICE_DISCONNECTED)
    }

    private fun pump() {
        if (current != null) return
        if (holdTasks && initWaiting.isEmpty()) {
            val callback = drained ?: return
            holdTasks = false
            drained = null
            callback()
        }
        val next = initWaiting.removeFirstOrNull() ?: waiting.removeFirstOrNull() ?: return
        current = next
        next.start()
    }
}
