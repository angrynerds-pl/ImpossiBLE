package com.impossible.ble

import android.os.Handler
import android.os.Looper
import android.util.Log
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

object ImpossibleBle {
    const val DEFAULT_HOST = "10.0.2.2"
    const val DEFAULT_PORT = 7700
    private const val TAG = "ImpossibleBle"

    @Volatile
    var connectionState: ConnectionState = ConnectionState.Disconnected
        private set

    private class Runtime(
        val connection: Connection,
        val scanner: Scanner,
        val session: Session,
        val identity: Identity,
    )

    @Volatile
    private var runtime: Runtime? = null

    @Synchronized
    fun configure(
        bundleId: String,
        token: String,
        host: String = DEFAULT_HOST,
        port: Int = DEFAULT_PORT,
        requestTimeoutMs: Long = Session.DEFAULT_REQUEST_TIMEOUT_MS,
    ) {
        if (token.isEmpty()) Log.w(TAG, "no relay token configured; the provider will reject the connection (set com.impossible.ble.TOKEN)")
        runtime?.let {
            it.connection.stop()
            it.session.shutdown()
        }
        val scheduler = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "impossible-ble-session").apply { isDaemon = true } }
        val main = Handler(Looper.getMainLooper())
        lateinit var connection: Connection
        val identity = Identity()
        val session = Session(scheduler, Executor { main.post(it) }, requestTimeoutMs) { connection.send(it) }
        val scanner = Scanner(session, identity)
        val listener = object : ConnectionListener {
            override fun onState(state: ConnectionState) {
                connectionState = state
                Log.i(TAG, "transport $state")
                if (state == ConnectionState.Connected) scanner.onTransportUp() else session.onTransportLost()
            }

            override fun onMessage(message: Incoming) = session.onMessage(message)

            override fun onClosedWithoutReply() {
                Log.w(TAG, "relay closed the connection without replying to hello; the token is probably wrong or stale")
            }
        }
        connection = Connection(host, port, Wire.hello(Wire.CLIENT_VERSION, bundleId, token), scheduler, listener)
        runtime = Runtime(connection, scanner, session, identity)
        connection.start()
    }

    internal fun session(): Session = runtime?.session ?: error("ImpossibleBle.configure was not called")

    internal fun identity(): Identity = runtime?.identity ?: error("ImpossibleBle.configure was not called")

    internal fun scanner(): Scanner = runtime?.scanner ?: error("ImpossibleBle.configure was not called")
}
