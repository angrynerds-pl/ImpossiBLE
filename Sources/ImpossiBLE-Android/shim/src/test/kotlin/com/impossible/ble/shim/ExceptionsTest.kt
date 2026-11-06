package com.impossible.ble.shim

import com.google.common.truth.Truth.assertThat
import no.nordicsemi.android.ble.WriteRequest
import no.nordicsemi.android.ble.exception.BluetoothDisabledException
import no.nordicsemi.android.ble.exception.ConnectionException
import no.nordicsemi.android.ble.exception.DeviceDisconnectedException
import no.nordicsemi.android.ble.exception.InvalidRequestException
import no.nordicsemi.android.ble.exception.RequestFailedException
import org.junit.Test

class ExceptionsTest {

    private val request = WriteRequest("write", null)

    @Test
    fun `given the 2_6_0 hierarchy, then disconnect and disabled are connection exceptions and the other two are plain exceptions`() {
        assertThat(DeviceDisconnectedException()).isInstanceOf(ConnectionException::class.java)
        assertThat(BluetoothDisabledException()).isInstanceOf(ConnectionException::class.java)
        assertThat(ConnectionException()).isNotInstanceOf(RequestFailedException::class.java)
        assertThat(RequestFailedException(request, 133)).isNotInstanceOf(ConnectionException::class.java)
        assertThat(InvalidRequestException(request)).isNotInstanceOf(ConnectionException::class.java)
        assertThat(RequestFailedException(request, 133).status).isEqualTo(133)
        assertThat(RequestFailedException(request, 133).request).isSameInstanceAs(request)
    }
}
