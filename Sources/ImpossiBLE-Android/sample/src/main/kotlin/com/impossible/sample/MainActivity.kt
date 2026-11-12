package com.impossible.sample

import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import com.impossible.ble.BleDevice
import com.impossible.ble.BleGatt
import com.impossible.ble.ImpossibleBle
import no.nordicsemi.android.ble.BleManager
import no.nordicsemi.android.support.v18.scanner.BluetoothLeScannerCompat
import no.nordicsemi.android.support.v18.scanner.ScanCallback
import no.nordicsemi.android.support.v18.scanner.ScanResult

/** Scans through ImpossiBLE, connects to the tapped device and lists its services. */
class MainActivity : Activity() {
    private val devices = LinkedHashMap<String, BleDevice>()
    private lateinit var adapter: ArrayAdapter<String>
    private lateinit var status: TextView
    private var manager: BleManager? = null

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            runOnUiThread {
                val device = result.device
                if (devices.put(device.address, device) == null) {
                    adapter.add("${device.name ?: "(unnamed)"}  ${device.address}  ${result.rssi} dBm")
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        adapter = ArrayAdapter(this, android.R.layout.simple_list_item_1)
        status = TextView(this).apply { text = "relay: ${ImpossibleBle.connectionState}" }
        val scan = Button(this).apply {
            text = "Scan"
            setOnClickListener { startScan() }
        }
        val list = ListView(this).apply {
            this.adapter = this@MainActivity.adapter
            setOnItemClickListener { _, _, position, _ -> connect(devices.values.elementAt(position)) }
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(24, 48, 24, 24)
            addView(status)
            addView(scan)
            addView(list, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        })
    }

    override fun onDestroy() {
        BluetoothLeScannerCompat.getScanner().stopScan(callback)
        manager?.disconnect()?.enqueue()
        super.onDestroy()
    }

    private fun startScan() {
        devices.clear()
        adapter.clear()
        status.text = "relay: ${ImpossibleBle.connectionState} — scanning"
        BluetoothLeScannerCompat.getScanner().startScan(callback)
    }

    private fun connect(device: BleDevice) {
        BluetoothLeScannerCompat.getScanner().stopScan(callback)
        status.text = "connecting to ${device.name ?: device.address}"
        manager?.disconnect()?.enqueue()
        manager = SampleManager(this) { services -> runOnUiThread { status.text = services } }.also {
            it.connect(device)
                .retry(2, 200)
                .timeout(15_000)
                .fail { _, reason -> runOnUiThread { status.text = "connect failed ($reason)" } }
                .enqueue()
        }
    }

    private class SampleManager(activity: Activity, private val onServices: (String) -> Unit) : BleManager(activity) {
        override fun isRequiredServiceSupported(gatt: BleGatt): Boolean {
            onServices("services:\n" + gatt.services.joinToString("\n") { it.uuid.toString() })
            return true
        }
    }
}
