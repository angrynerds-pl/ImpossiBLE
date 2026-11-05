package no.nordicsemi.android.ble

import no.nordicsemi.android.ble.callback.DataReceivedCallback

class ValueChangedCallback internal constructor() {
    internal var dataCallback: DataReceivedCallback? = null

    fun with(callback: DataReceivedCallback) = apply { dataCallback = callback }
}
