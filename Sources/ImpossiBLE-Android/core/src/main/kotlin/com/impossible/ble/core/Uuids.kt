package com.impossible.ble.core

import java.security.MessageDigest
import java.util.Locale

object Uuids {
    private const val SHORT = 4
    private const val MEDIUM = 8
    private const val BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"
    private const val MAC_BYTES = 6
    private const val LOCALLY_ADMINISTERED = 0x02

    fun expand(uuid: String): String {
        val u = uuid.lowercase(Locale.ROOT)
        return when (u.length) {
            SHORT -> "0000$u$BASE_SUFFIX"
            MEDIUM -> "$u$BASE_SUFFIX"
            else -> u
        }
    }

    fun mac(peripheralUuid: String): String {
        val hash = MessageDigest.getInstance("SHA-1").digest(peripheralUuid.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
        val bytes = byteArrayOf(LOCALLY_ADMINISTERED.toByte()) + hash.copyOfRange(0, MAC_BYTES - 1)
        return bytes.joinToString(":") { String.format(Locale.ROOT, "%02X", it) }
    }
}

class Identity {
    private val addresses = HashMap<String, String>()
    private val uuids = HashMap<String, String>()

    @Synchronized
    fun addressFor(uuid: String): String = addresses.getOrPut(uuid) { Uuids.mac(uuid).also { uuids[it] = uuid } }

    @Synchronized
    fun uuidFor(address: String): String? = uuids[address]
}
