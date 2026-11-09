package com.impossible.ble.core

import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class Fixture(val callbacks: Executor = Executor { it.run() }) {
    val scheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    val queue = RequestQueue(scheduler, callbacks)
    val sent = java.util.concurrent.CopyOnWriteArrayList<String>()
    val session = Session(scheduler, callbacks) { line -> sent += line; true }

    fun drain() {
        scheduler.submit {}.get(WAIT_S, TimeUnit.SECONDS)
    }

    fun incoming(line: String) {
        session.onMessage(Wire.decode(line))
        drain()
    }

    fun awaitThat(condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(WAIT_S)
        while (!condition()) {
            if (System.nanoTime() > deadline) throw TimeoutException("condition not met")
            Thread.sleep(POLL_MS)
        }
    }

    fun close() {
        scheduler.shutdownNow()
    }

    companion object {
        const val WAIT_S = 5L
        const val POLL_MS = 5L
    }
}
