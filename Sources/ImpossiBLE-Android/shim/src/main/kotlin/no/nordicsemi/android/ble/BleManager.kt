package no.nordicsemi.android.ble

import android.bluetooth.BluetoothGattCharacteristic
import android.content.Context
import com.impossible.ble.BleDevice
import com.impossible.ble.BleGatt
import no.nordicsemi.android.ble.data.Data
import no.nordicsemi.android.ble.observer.ConnectionObserver

// ponytail: requests are built without an operation until the BleManager milestone wires connect, discovery, init and GATT traffic.
@Suppress("UNUSED_PARAMETER", "TooManyFunctions")
abstract class BleManager(protected val context: Context) {
    var connectionObserver: ConnectionObserver? = null

    var bluetoothDevice: BleDevice? = null
        private set

    val isConnected: Boolean get() = false

    val isReady: Boolean get() = false

    val connectionState: Int get() = 0

    protected open fun initialize() = Unit

    protected open fun isRequiredServiceSupported(gatt: BleGatt): Boolean = true

    protected open fun isOptionalServiceSupported(gatt: BleGatt): Boolean = false

    protected open fun onServicesInvalidated() = Unit

    protected open fun onDeviceReady() = Unit

    fun connect(device: BleDevice): ConnectRequest = ConnectRequest("connect", null)

    fun disconnect(): DisconnectRequest = DisconnectRequest("disconnect", null)

    protected fun setNotificationCallback(characteristic: BluetoothGattCharacteristic?): ValueChangedCallback = ValueChangedCallback()

    protected fun enableNotifications(characteristic: BluetoothGattCharacteristic?): WriteRequest = WriteRequest("enableNotifications", null)

    protected fun readCharacteristic(characteristic: BluetoothGattCharacteristic?): ReadRequest = ReadRequest("readCharacteristic", null)

    protected fun writeCharacteristic(characteristic: BluetoothGattCharacteristic?, data: Data?, writeType: Int): WriteRequest =
        WriteRequest("writeCharacteristic", null)

    protected fun writeCharacteristic(characteristic: BluetoothGattCharacteristic?, data: ByteArray?, writeType: Int): WriteRequest =
        WriteRequest("writeCharacteristic", null)

    protected fun requestMtu(mtu: Int): MtuRequest = MtuRequest("requestMtu", null)

    protected fun requestConnectionPriority(priority: Int): ConnectionPriorityRequest = ConnectionPriorityRequest("requestConnectionPriority", null)
}
