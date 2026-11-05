package com.impossible.ble.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.Base64

sealed interface Incoming

class Advertisement(
    val localName: String?,
    val serviceUuids: List<String>,
    val manufacturerData: ByteArray?,
    val serviceData: Map<String, ByteArray>,
    val connectable: Boolean?,
)

class DidDiscover(val id: String, val name: String, val rssi: Int, val adv: Advertisement) : Incoming
data class DidConnect(val id: String, val maxWriteWithResponse: Int?, val maxWriteWithoutResponse: Int?) : Incoming
data class DidFailConnect(val id: String, val error: String) : Incoming
data class DidDisconnect(val id: String, val error: String) : Incoming
data class DidWriteValue(val id: String, val characteristicId: String, val error: String, val writeType: Int?) : Incoming
data class DidUpdateNotification(val id: String, val characteristicId: String, val enabled: Boolean, val error: String) : Incoming
data class ConnectionRejected(val retry: Boolean) : Incoming
data class Unknown(val type: String) : Incoming

class DidUpdateValue(
    val id: String,
    val characteristicId: String,
    val value: ByteArray,
    val error: String,
    val isNotification: Boolean?,
) : Incoming

object Wire {
    private const val ADV_NAME = "kCBAdvDataLocalName"
    private const val ADV_SERVICES = "kCBAdvDataServiceUUIDs"
    private const val ADV_MANUFACTURER = "kCBAdvDataManufacturerData"
    private const val ADV_SERVICE_DATA = "kCBAdvDataServiceData"
    private const val ADV_CONNECTABLE = "kCBAdvDataIsConnectable"
    private const val ALLOW_DUPLICATES = "kCBScanOptionAllowDuplicates"

    fun hello(clientVersion: String, bundleId: String, token: String): String = line {
        put("type", "hello")
        put("clientVersion", clientVersion)
        put("bundleId", bundleId)
        put("pid", 0)
        put("platform", "android")
        put("token", token)
    }

    fun scan(services: List<String>): String = line {
        put("type", "scan")
        putJsonArray("services") { services.forEach { add(JsonPrimitive(it)) } }
        putJsonObject("options") { put(ALLOW_DUPLICATES, true) }
    }

    fun stopScan(): String = line { put("type", "stopScan") }

    fun connect(id: String): String = line { put("type", "connect"); put("id", id) }

    fun cancel(id: String): String = line { put("type", "cancel"); put("id", id) }

    fun read(id: String, characteristicId: String): String = line {
        put("type", "read")
        put("id", id)
        put("characteristicId", characteristicId)
    }

    fun write(id: String, characteristicId: String, value: ByteArray, withResponse: Boolean): String = line {
        put("type", "write")
        put("id", id)
        put("characteristicId", characteristicId)
        put("value", Base64.getEncoder().encodeToString(value))
        put("writeType", if (withResponse) 0 else 1)
    }

    fun setNotify(id: String, characteristicId: String, enabled: Boolean): String = line {
        put("type", "setNotify")
        put("id", id)
        put("characteristicId", characteristicId)
        put("enabled", enabled)
    }

    fun decode(line: String): Incoming {
        val o = runCatching { Json.parseToJsonElement(line).jsonObject }.getOrNull() ?: return Unknown("")
        val type = o.str("type") ?: return Unknown("")
        return runCatching { decodeKnown(type, o) }.getOrNull() ?: Unknown(type)
    }

    private fun decodeKnown(type: String, o: JsonObject): Incoming? {
        val id = o.str("id")
        val ch = o.str("characteristicId")
        val error = o.str("error").orEmpty()
        return when (type) {
            "didDiscover" -> id?.let { DidDiscover(it, o.str("name").orEmpty(), o.int("rssi") ?: 0, advertisement(o["adv"])) }
            "didConnect" -> id?.let { DidConnect(it, o.int("maxWriteWithResponse"), o.int("maxWriteWithoutResponse")) }
            "didFailConnect" -> id?.let { DidFailConnect(it, error) }
            "didDisconnect" -> id?.let { DidDisconnect(it, error) }
            "didUpdateValue" -> if (id != null && ch != null) {
                DidUpdateValue(id, ch, bytes(o.str("value")), error, o.bool("isNotification"))
            } else {
                null
            }
            "didWriteValue" -> if (id != null && ch != null) DidWriteValue(id, ch, error, o.int("writeType")) else null
            "didUpdateNotification" -> if (id != null && ch != null) {
                DidUpdateNotification(id, ch, o.bool("enabled") ?: false, error)
            } else {
                null
            }
            "connectionRejected" -> ConnectionRejected(o.bool("retry") ?: false)
            else -> null
        }
    }

    private fun advertisement(element: JsonElement?): Advertisement {
        val adv = element as? JsonObject ?: JsonObject(emptyMap())
        val services = (adv[ADV_SERVICES] as? JsonArray)?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
        val serviceData = (adv[ADV_SERVICE_DATA] as? JsonObject)?.mapValues { bytes(it.value.jsonPrimitive.contentOrNull) }.orEmpty()
        return Advertisement(
            adv.str(ADV_NAME),
            services,
            adv.str(ADV_MANUFACTURER)?.let { bytes(it) },
            serviceData,
            adv.bool(ADV_CONNECTABLE),
        )
    }

    private fun bytes(base64: String?): ByteArray = if (base64.isNullOrEmpty()) ByteArray(0) else Base64.getDecoder().decode(base64)

    private fun JsonObject.str(key: String) = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

    private fun JsonObject.int(key: String) = (this[key] as? JsonPrimitive)?.intOrNull

    private fun JsonObject.bool(key: String) = (this[key] as? JsonPrimitive)?.booleanOrNull

    private fun line(build: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit): String = buildJsonObject(build).toString()
}
