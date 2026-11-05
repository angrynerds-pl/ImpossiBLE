package com.impossible.ble

import android.os.Handler
import android.os.Looper
import com.impossible.ble.core.Connection
import com.impossible.ble.core.ConnectionListener
import com.impossible.ble.core.ConnectionState
import com.impossible.ble.core.Identity
import com.impossible.ble.core.Incoming
import com.impossible.ble.core.Scanner
import com.impossible.ble.core.Session
import com.impossible.ble.core.Wire
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService

object ImpossibleBle {
    const val DEFAULT_HOST = "10.0.2.2"
    const val DEFAULT_PORT = 7700
    private const val CLIENT_VERSION = "0.1.0"

    @Volatile
    var connectionState: ConnectionState = ConnectionState.Disconnected
        private set

    private class Runtime(val connection: Connection, val scheduler: ScheduledExecutorService, val scanner: Scanner)

    @Volatile
    private var runtime: Runtime? = null

    @Synchronized
    fun configure(bundleId: String, token: String, host: String = DEFAULT_HOST, port: Int = DEFAULT_PORT) {
        runtime?.let {
            it.connection.stop()
            it.scheduler.shutdownNow()
        }
        val scheduler = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "impossible-ble-session").apply { isDaemon = true } }
        val main = Handler(Looper.getMainLooper())
        lateinit var connection: Connection
        val session = Session(scheduler, Executor { main.post(it) }) { connection.send(it) }
        val listener = object : ConnectionListener {
            override fun onState(state: ConnectionState) {
                connectionState = state
                if (state != ConnectionState.Connected) session.onTransportLost()
            }

            override fun onMessage(message: Incoming) = session.onMessage(message)
        }
        connection = Connection(host, port, Wire.hello(CLIENT_VERSION, bundleId, token), scheduler, listener)
        runtime = Runtime(connection, scheduler, Scanner(session, Identity()))
        connection.start()
    }

    internal fun scanner(): Scanner = runtime?.scanner ?: error("ImpossibleBle.configure was not called")
}
