package com.impossible.ble.shim

import android.os.Looper

internal object MainThread {
    val default: () -> Boolean = { Looper.myLooper() == Looper.getMainLooper() }

    @Volatile
    var isMain: () -> Boolean = default
}
