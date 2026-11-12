package no.nordicsemi.android.ble

import no.nordicsemi.android.ble.callback.DataReceivedCallback

class ValueChangedCallback internal constructor(private val register: (DataReceivedCallback) -> Unit = {}) {

    fun with(callback: DataReceivedCallback) = apply { register(callback) }
}
