package com.impossible.sample

import android.app.Activity
import android.bluetooth.BluetoothGattCharacteristic
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.ScrollView
import android.widget.TextView
import com.impossible.ble.BleDevice
import com.impossible.ble.BleGatt
import com.impossible.ble.ImpossibleBle
import com.impossible.ble.core.ConnectionState
import no.nordicsemi.android.ble.BleManager
import no.nordicsemi.android.ble.observer.ConnectionObserver
import no.nordicsemi.android.support.v18.scanner.BluetoothLeScannerCompat
import no.nordicsemi.android.support.v18.scanner.ScanCallback
import no.nordicsemi.android.support.v18.scanner.ScanResult

/**
 * Scans through ImpossiBLE and shows each stage on screen: the relay link, the
 * discoverable devices, the connection to the tapped one, and its characteristics.
 */
class MainActivity : Activity() {
    private val WRAP = ViewGroup.LayoutParams.WRAP_CONTENT
    private class Found(val device: BleDevice, val rssi: Int, val isPm: Boolean)

    private val found = ArrayList<Found>()
    private val ui = Handler(Looper.getMainLooper())
    private val rows = ArrayList<Pair<String, String>>()
    private lateinit var adapter: ArrayAdapter<Pair<String, String>>
    private lateinit var relayStatus: TextView
    private lateinit var deviceStatus: TextView
    private lateinit var characteristics: TextView
    private var manager: BleManager? = null

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            runOnUiThread {
                val device = result.device
                if (found.none { it.device == device }) {
                    val advertised = result.scanRecord?.serviceUuids.orEmpty()
                    found += Found(device, result.rssi, isPm(device.name, advertised.map { it.toString() }))
                    // PMs first, then by signal strength.
                    found.sortWith(compareByDescending<Found> { it.isPm }.thenByDescending { it.rssi })
                    adapter.clear()
                    adapter.addAll(found.map { (it.device.name ?: "(unnamed)") to "${it.device.address}   ${it.rssi} dBm" + if (it.isPm) "   PM" else "" })
                }
            }
        }
    }

    // ImpossibleBle exposes the relay state as a property only, so poll it.
    private val relayPoll = object : Runnable {
        override fun run() {
            val state = ImpossibleBle.connectionState
            relayStatus.text = "Relay: $state"
            relayStatus.setBackgroundColor(
                when (state) {
                    ConnectionState.Connected -> Color.rgb(46, 160, 67)
                    ConnectionState.Connecting -> Color.rgb(210, 153, 34)
                    else -> Color.rgb(207, 34, 46)
                },
            )
            ui.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        adapter = object : ArrayAdapter<Pair<String, String>>(this, 0, rows) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val (title, detail) = getItem(position)!!
                return LinearLayout(context).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(dp(16), dp(10), dp(16), dp(10))
                    addView(TextView(context).apply { text = title; textSize = 16f; setTextColor(Color.BLACK); setTypeface(typeface, Typeface.BOLD) })
                    addView(TextView(context).apply { text = detail; textSize = 12f; setTextColor(Color.GRAY) })
                }
            }
        }
        relayStatus = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(14), dp(16), dp(14))
        }
        deviceStatus = body("No device connected")
        characteristics = body("Connect to a device to see its characteristics.").apply { typeface = Typeface.MONOSPACE; textSize = 12f }
        val scan = Button(this).apply {
            text = "Scan for devices"
            setOnClickListener { startScan() }
        }
        val empty = body("No devices yet. Tap Scan.")
        val list = ListView(this).apply {
            this.adapter = this@MainActivity.adapter
            emptyView = empty
            setOnItemClickListener { _, _, position, _ -> connect(found[position].device) }
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            fitsSystemWindows = true
            setBackgroundColor(Color.WHITE)
            addView(relayStatus)
            addView(scan, LinearLayout.LayoutParams(MATCH_PARENT, WRAP).apply { setMargins(dp(16), dp(12), dp(16), dp(4)) })
            addView(header("DEVICES (TAP TO CONNECT)"))
            addView(FrameLayout(this@MainActivity).apply { addView(list); addView(empty) }, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
            addView(header("CONNECTION"))
            addView(deviceStatus)
            addView(header("CHARACTERISTICS"))
            addView(ScrollView(this@MainActivity).apply { addView(characteristics) }, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1.4f))
        }
        setContentView(root, ViewGroup.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        relayPoll.run()
    }

    override fun onDestroy() {
        ui.removeCallbacks(relayPoll)
        BluetoothLeScannerCompat.getScanner().stopScan(callback)
        manager?.disconnect()?.enqueue()
        super.onDestroy()
    }

    private fun startScan() {
        found.clear()
        adapter.clear()
        BluetoothLeScannerCompat.getScanner().startScan(callback)
    }

    private fun connect(device: BleDevice) {
        BluetoothLeScannerCompat.getScanner().stopScan(callback)
        manager?.disconnect()?.enqueue()
        characteristics.text = ""
        val name = device.name ?: device.address
        val next = SampleManager(this, { runOnUiThread(it) }, { text -> characteristics.text = text })
        next.connectionObserver = object : ConnectionObserver {
            override fun onDeviceConnecting(device: BleDevice) = show("Connecting to $name…")
            override fun onDeviceConnected(device: BleDevice) = show("Connected to $name, discovering services…")
            override fun onDeviceReady(device: BleDevice) = show("Ready: $name")
            override fun onDeviceFailedToConnect(device: BleDevice, reason: Int) = show("Failed to connect to $name (reason $reason)")
            override fun onDeviceDisconnecting(device: BleDevice) = show("Disconnecting from $name…")
            override fun onDeviceDisconnected(device: BleDevice, reason: Int) = show("Disconnected from $name (reason $reason)")
        }
        manager = next
        deviceStatus.text = "Connecting to $name…"
        next.connect(device).retry(2, 200).timeout(15_000).enqueue()
    }

    private fun show(text: String) = runOnUiThread { deviceStatus.text = text }

    /** A Concept2 PM: named "PM<n> …" or advertising a service of the Concept2 UUID base (CE06xxxx-43E5-11E4-916C-0800200C9A66). */
    private fun isPm(name: String?, serviceUuids: List<String>) =
        name?.matches(Regex("PM\\d.*")) == true || serviceUuids.any { it.startsWith("ce06", ignoreCase = true) }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun body(text: String) = TextView(this).apply {
        this.text = text
        setPadding(dp(16), dp(10), dp(16), dp(10))
    }

    private fun header(text: String) = TextView(this).apply {
        this.text = text
        textSize = 11f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(Color.DKGRAY)
        setBackgroundColor(Color.rgb(238, 238, 240))
        setPadding(dp(16), dp(6), dp(16), dp(6))
    }

    private class SampleManager(
        activity: Activity,
        private val onMain: (() -> Unit) -> Unit,
        private val onServices: (String) -> Unit,
    ) : BleManager(activity) {
        override fun isRequiredServiceSupported(gatt: BleGatt): Boolean {
            val text = gatt.services.joinToString("\n\n") { service ->
                "Service ${service.uuid}\n" + service.characteristics.joinToString("\n") {
                    "  ${it.uuid}  [${properties(it.properties)}]"
                }
            }.ifEmpty { "(no services)" }
            onMain { onServices(text) }
            return true
        }

        private fun properties(bits: Int) = listOf(
            BluetoothGattCharacteristic.PROPERTY_READ to "READ",
            BluetoothGattCharacteristic.PROPERTY_WRITE to "WRITE",
            BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE to "WRITE_NO_RESP",
            BluetoothGattCharacteristic.PROPERTY_NOTIFY to "NOTIFY",
            BluetoothGattCharacteristic.PROPERTY_INDICATE to "INDICATE",
        ).filter { bits and it.first != 0 }.joinToString(" ") { it.second }
    }
}
