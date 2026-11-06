package no.nordicsemi.android.ble

import com.impossible.ble.BleDevice
import no.nordicsemi.android.ble.callback.AfterCallback
import no.nordicsemi.android.ble.callback.DataReceivedCallback
import no.nordicsemi.android.ble.callback.FailCallback
import no.nordicsemi.android.ble.callback.InvalidRequestCallback
import no.nordicsemi.android.ble.callback.SuccessCallback
import no.nordicsemi.android.ble.data.Data
import com.impossible.ble.core.Request as CoreRequest

private typealias Factory = ((Request) -> CoreRequest<BleDevice>)?

class ConnectRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    internal var autoConnect = false
    internal var preferredPhy = 0
    internal var retryCount = 0
    internal var retryDelayMillis = 0

    fun timeout(millis: Long) = apply { timeoutMillis = millis }

    fun retry(count: Int) = retry(count, 0)

    fun retry(count: Int, delayMillis: Int) = apply {
        retryCount = count
        retryDelayMillis = delayMillis
    }

    fun useAutoConnect(enabled: Boolean) = apply { autoConnect = enabled }

    fun usePreferredPhy(phyMask: Int) = apply { preferredPhy = phyMask }

    override fun done(callback: SuccessCallback): ConnectRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): ConnectRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): ConnectRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): ConnectRequest = apply { super.then(callback) }
}

class DisconnectRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    fun timeout(millis: Long) = apply { timeoutMillis = millis }

    override fun done(callback: SuccessCallback): DisconnectRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): DisconnectRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): DisconnectRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): DisconnectRequest = apply { super.then(callback) }
}

class ReadRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    private var dataCallback: DataReceivedCallback? = null

    fun with(callback: DataReceivedCallback) = apply { dataCallback = callback }

    override fun onSucceeded(core: CoreRequest<BleDevice>) {
        dataCallback?.onDataReceived(core.device, Data(core.value))
    }

    override fun done(callback: SuccessCallback): ReadRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): ReadRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): ReadRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): ReadRequest = apply { super.then(callback) }
}

class WriteRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    internal var splitEnabled = false

    fun split() = apply { splitEnabled = true }

    override fun done(callback: SuccessCallback): WriteRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): WriteRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): WriteRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): WriteRequest = apply { super.then(callback) }
}

class MtuRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    override fun done(callback: SuccessCallback): MtuRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): MtuRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): MtuRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): MtuRequest = apply { super.then(callback) }
}

class SimpleRequest internal constructor(name: String, factory: Factory) : Request(name, factory)

class ConnectionPriorityRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    override fun done(callback: SuccessCallback): ConnectionPriorityRequest = apply { super.done(callback) }

    override fun fail(callback: FailCallback): ConnectionPriorityRequest = apply { super.fail(callback) }

    override fun invalid(callback: InvalidRequestCallback): ConnectionPriorityRequest = apply { super.invalid(callback) }

    override fun then(callback: AfterCallback): ConnectionPriorityRequest = apply { super.then(callback) }

    companion object {
        const val CONNECTION_PRIORITY_BALANCED = 0
        const val CONNECTION_PRIORITY_HIGH = 1
        const val CONNECTION_PRIORITY_LOW_POWER = 2
    }
}

class PhyRequest internal constructor(name: String, factory: Factory) : Request(name, factory) {
    companion object {
        const val PHY_LE_1M_MASK = 1
        const val PHY_LE_2M_MASK = 2
        const val PHY_LE_CODED_MASK = 4
        const val PHY_OPTION_NO_PREFERRED = 0
        const val PHY_OPTION_S2 = 1
        const val PHY_OPTION_S8 = 2
    }
}
