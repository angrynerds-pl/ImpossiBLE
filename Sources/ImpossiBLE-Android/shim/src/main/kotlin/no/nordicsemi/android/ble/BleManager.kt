package no.nordicsemi.android.ble

import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.content.Context
import com.impossible.ble.BleDevice
import com.impossible.ble.BleGatt
import com.impossible.ble.ImpossibleBle
import com.impossible.ble.core.DiscoveredCharacteristic
import com.impossible.ble.core.DiscoveredService
import com.impossible.ble.core.Link
import com.impossible.ble.core.LinkHooks
import com.impossible.ble.core.Reason
import no.nordicsemi.android.ble.data.Data
import no.nordicsemi.android.ble.observer.ConnectionObserver
import java.util.UUID
import com.impossible.ble.core.Request as CoreRequest

private typealias CoreFactory = (Request) -> CoreRequest<BleDevice>

@Suppress("TooManyFunctions")
abstract class BleManager(protected val context: Context) {
    var connectionObserver: ConnectionObserver? = null

    var bluetoothDevice: BleDevice? = null
        private set

    @Volatile
    private var link: Link<BleDevice>? = null

    @Volatile
    private var mtu = DEFAULT_MTU

    val isConnected: Boolean get() = link?.isConnected == true

    val isReady: Boolean get() = link?.isReady == true

    val connectionState: Int get() = if (isConnected) STATE_CONNECTED else STATE_DISCONNECTED

    protected open fun initialize() = Unit

    protected open fun isRequiredServiceSupported(gatt: BleGatt): Boolean = true

    protected open fun isOptionalServiceSupported(gatt: BleGatt): Boolean = false

    protected open fun onServicesInvalidated() = Unit

    protected open fun onDeviceReady() = Unit

    fun connect(device: BleDevice): ConnectRequest {
        bluetoothDevice = device
        return ConnectRequest("connect") { request ->
            val peripheral = ImpossibleBle.identity().uuidFor(device.address)
            val active = link?.takeIf { it.device == device } ?: peripheral?.let { newLink(it, device) }
            if (active == null) {
                detached(device) { it.failWith(Reason.REQUEST_FAILED) }
            } else {
                request as ConnectRequest
                active.connect().retry(request.retryCount, request.retryDelayMillis.toLong())
            }
        }
    }

    fun disconnect(): DisconnectRequest = DisconnectRequest("disconnect") {
        link?.disconnect() ?: detached(bluetoothDevice) { r -> r.succeed() }
    }

    protected fun setNotificationCallback(characteristic: BluetoothGattCharacteristic?): ValueChangedCallback = ValueChangedCallback { callback ->
        val active = link
        val id = characteristic?.let { active?.characteristicIdOf(it) }
        if (active != null && id != null) {
            ImpossibleBle.session().setNotificationCallback(active.peripheralId, id) { bytes ->
                callback.onDataReceived(active.device, Data(bytes))
            }
        }
    }

    protected fun enableNotifications(characteristic: BluetoothGattCharacteristic?): WriteRequest =
        WriteRequest("enableNotifications", attribute(characteristic, NOTIFY_OR_INDICATE) { l, id -> l.setNotify(id, true) })

    protected fun readCharacteristic(characteristic: BluetoothGattCharacteristic?): ReadRequest =
        ReadRequest("readCharacteristic", attribute(characteristic, BluetoothGattCharacteristic.PROPERTY_READ) { l, id -> l.read(id) })

    protected fun writeCharacteristic(characteristic: BluetoothGattCharacteristic?, data: Data?, writeType: Int): WriteRequest =
        writeCharacteristic(characteristic, data?.value, writeType)

    protected fun writeCharacteristic(characteristic: BluetoothGattCharacteristic?, data: ByteArray?, writeType: Int): WriteRequest {
        val withResponse = writeType != BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val bytes = data ?: ByteArray(0)
        lateinit var request: WriteRequest
        request = WriteRequest("writeCharacteristic", attribute(characteristic, 0) { l, id ->
            if (request.splitEnabled) l.writeSplit(id, bytes, withResponse) else l.write(id, bytes, withResponse)
        })
        return request
    }

    protected fun requestMtu(mtu: Int): MtuRequest = MtuRequest("requestMtu", local { l ->
        l.local { r ->
            this.mtu = ImpossibleBle.session().maxWrite(l.peripheralId, false) + ATT_HEADER
            r.succeed()
        }
    })

    protected fun requestConnectionPriority(priority: Int): ConnectionPriorityRequest =
        ConnectionPriorityRequest("requestConnectionPriority", local { l -> l.local { r -> r.succeed() } })

    private fun newLink(peripheral: String, device: BleDevice): Link<BleDevice> =
        Link(ImpossibleBle.session(), peripheral, device, Hooks(device)).also { link = it }

    private fun attribute(
        characteristic: BluetoothGattCharacteristic?,
        requiredProperties: Int,
        operation: (Link<BleDevice>, String) -> CoreRequest<BleDevice>,
    ): CoreFactory = local { l ->
        val id = characteristic?.let { l.characteristicIdOf(it) }
        if (id == null || (requiredProperties != 0 && (characteristic.properties and requiredProperties) == 0)) {
            l.local(queued = false) { it.invalidate() }
        } else {
            operation(l, id)
        }
    }

    private fun local(build: (Link<BleDevice>) -> CoreRequest<BleDevice>): CoreFactory = {
        val active = link
        if (active == null || !active.isConnected) {
            detached(bluetoothDevice) { r -> r.failWith(Reason.DEVICE_DISCONNECTED) }
        } else {
            build(active)
        }
    }

    private fun detached(device: BleDevice?, operation: (CoreRequest<BleDevice>) -> Unit): CoreRequest<BleDevice> =
        ImpossibleBle.session().queueFor("").request(device ?: BleDevice(NO_ADDRESS, null), false, operation)

    private fun Link<BleDevice>.characteristicIdOf(characteristic: BluetoothGattCharacteristic): String? =
        characteristicId(characteristic.service?.uuid.toString(), characteristic.uuid.toString())

    private inner class Hooks(private val device: BleDevice) : LinkHooks {
        private var gatt: BleGatt? = null

        override fun onConnecting() = observe { onDeviceConnecting(device) }

        override fun onConnected() = observe { onDeviceConnected(device) }

        override fun onFailedToConnect(reason: Int) = observe { onDeviceFailedToConnect(device, reason) }

        override fun onDisconnecting() = observe { onDeviceDisconnecting(device) }

        override fun onDisconnected(reason: Int) = observe { onDeviceDisconnected(device, reason) }

        override fun onReady() = observe { onDeviceReady(device) }

        override fun requiredSupported(services: List<DiscoveredService>): Boolean =
            BleGatt(services.map(::gattService)).also { gatt = it }.let { isRequiredServiceSupported(it) }

        override fun optionalSupported() {
            gatt?.let { isOptionalServiceSupported(it) }
        }

        override fun initialize() = this@BleManager.initialize()

        override fun onManagerReady() = this@BleManager.onDeviceReady()

        override fun onServicesInvalidated() = this@BleManager.onServicesInvalidated()

        private fun observe(call: ConnectionObserver.() -> Unit) {
            connectionObserver?.call()
        }

        private fun gattService(service: DiscoveredService): BluetoothGattService {
            val type = if (service.primary) BluetoothGattService.SERVICE_TYPE_PRIMARY else BluetoothGattService.SERVICE_TYPE_SECONDARY
            return BluetoothGattService(UUID.fromString(service.uuid), type).also { s ->
                service.characteristics.forEach { s.addCharacteristic(gattCharacteristic(it)) }
            }
        }

        private fun gattCharacteristic(info: DiscoveredCharacteristic): BluetoothGattCharacteristic {
            val permissions = (if (info.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0) BluetoothGattCharacteristic.PERMISSION_READ else 0) or
                (if (info.properties and WRITABLE != 0) BluetoothGattCharacteristic.PERMISSION_WRITE else 0)
            return BluetoothGattCharacteristic(UUID.fromString(info.uuid), info.properties, permissions).also { c ->
                if (info.properties and NOTIFY_OR_INDICATE != 0) {
                    c.addDescriptor(BluetoothGattDescriptor(CCCD, BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
                }
            }
        }
    }

    private companion object {
        const val STATE_DISCONNECTED = 0
        const val STATE_CONNECTED = 2
        const val DEFAULT_MTU = 23
        const val ATT_HEADER = 3
        const val NO_ADDRESS = "00:00:00:00:00:00"
        const val NOTIFY_OR_INDICATE = BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE
        const val WRITABLE = BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
