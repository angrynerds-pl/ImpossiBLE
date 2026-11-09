package no.nordicsemi.android.ble

import com.impossible.ble.BleDevice
import com.impossible.ble.core.Reason
import com.impossible.ble.shim.MainThread
import no.nordicsemi.android.ble.callback.AfterCallback
import no.nordicsemi.android.ble.callback.FailCallback
import no.nordicsemi.android.ble.callback.InvalidRequestCallback
import no.nordicsemi.android.ble.callback.SuccessCallback
import no.nordicsemi.android.ble.exception.BluetoothDisabledException
import no.nordicsemi.android.ble.exception.DeviceDisconnectedException
import no.nordicsemi.android.ble.exception.InvalidRequestException
import no.nordicsemi.android.ble.exception.RequestFailedException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import com.impossible.ble.core.Request as CoreRequest

abstract class Request internal constructor(
    private val name: String,
    private val factory: ((Request) -> CoreRequest<BleDevice>)?,
) {
    private var doneCallback: SuccessCallback? = null
    private var failCallback: FailCallback? = null
    private var invalidCallback: InvalidRequestCallback? = null
    private var afterCallback: AfterCallback? = null
    internal var timeoutMillis: Long? = null

    open fun done(callback: SuccessCallback): Request = apply { doneCallback = callback }

    open fun fail(callback: FailCallback): Request = apply { failCallback = callback }

    open fun invalid(callback: InvalidRequestCallback): Request = apply { invalidCallback = callback }

    open fun then(callback: AfterCallback): Request = apply { afterCallback = callback }

    fun enqueue() {
        build().enqueue()
    }

    @Throws(
        RequestFailedException::class,
        DeviceDisconnectedException::class,
        BluetoothDisabledException::class,
        InvalidRequestException::class,
    )
    fun await() {
        check(!MainThread.isMain()) { "Cannot execute synchronous operation from the UI thread." }
        val latch = CountDownLatch(1)
        val status = AtomicInteger()
        doneCallback = SuccessCallback { latch.countDown() }
        failCallback = FailCallback { _, s -> status.set(s); latch.countDown() }
        invalidCallback = InvalidRequestCallback { status.set(Reason.REQUEST_INVALID); latch.countDown() }
        val core = build()
        core.enqueue()
        if (!latch.await(core.awaitLimitMs, TimeUnit.MILLISECONDS)) {
            core.cancel()
            throw RequestFailedException(this, Reason.TIMEOUT)
        }
        when (val s = status.get()) {
            0 -> Unit
            Reason.DEVICE_DISCONNECTED -> throw DeviceDisconnectedException()
            Reason.BLUETOOTH_DISABLED -> throw BluetoothDisabledException()
            Reason.REQUEST_INVALID -> throw InvalidRequestException(this)
            else -> throw RequestFailedException(this, s)
        }
    }

    internal open fun onSucceeded(core: CoreRequest<BleDevice>) = Unit

    private fun build(): CoreRequest<BleDevice> {
        val create = factory ?: throw UnsupportedOperationException("ImpossiBLE shim: $name")
        val core = create(this)
        timeoutMillis?.let { core.timeout(it) }
        return core
            .done { device ->
                onSucceeded(core)
                doneCallback?.onRequestCompleted(device)
            }
            .fail { device, status -> failCallback?.onRequestFailed(device, status) }
            .invalid { invalidCallback?.onInvalidRequest() }
            .then { device -> afterCallback?.onRequestFinished(device) }
    }
}
