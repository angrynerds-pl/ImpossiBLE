package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test

class WireTest {

    private fun obj(line: String): JsonObject = Json.parseToJsonElement(line).jsonObject

    @Test
    fun `given hello, when encoded, then pid is zero and platform and token are present`() {
        val o = obj(Wire.hello("1.0", "com.concept2.ergdata", "tok"))
        assertThat(o["type"]?.jsonPrimitive?.content).isEqualTo("hello")
        assertThat(o["pid"]?.jsonPrimitive?.int).isEqualTo(0)
        assertThat(o["platform"]?.jsonPrimitive?.content).isEqualTo("android")
        assertThat(o["token"]?.jsonPrimitive?.content).isEqualTo("tok")
        assertThat(o["bundleId"]?.jsonPrimitive?.content).isEqualTo("com.concept2.ergdata")
        assertThat(o["clientVersion"]?.jsonPrimitive?.content).isEqualTo("1.0")
    }

    @Test
    fun `given encoded messages, then they are single lines`() {
        val lines = listOf(Wire.hello("1", "b", "t"), Wire.scan(listOf("CE060000-43E5-11E4-916C-0800200C9A66")), Wire.write("p", "c", byteArrayOf(1), true))
        lines.forEach { assertThat(it).doesNotContain("\n") }
    }

    @Test
    fun `given write, when encoded, then value is base64 and writeType follows response flag`() {
        val withResponse = obj(Wire.write("p", "c", byteArrayOf(1, 2, 3), true))
        assertThat(withResponse["value"]?.jsonPrimitive?.content).isEqualTo("AQID")
        assertThat(withResponse["writeType"]?.jsonPrimitive?.int).isEqualTo(0)
        assertThat(withResponse["characteristicId"]?.jsonPrimitive?.content).isEqualTo("c")
        assertThat(obj(Wire.write("p", "c", byteArrayOf(), false))["writeType"]?.jsonPrimitive?.int).isEqualTo(1)
        assertThat(obj(Wire.write("p", "c", byteArrayOf(), false))["value"]?.jsonPrimitive?.content).isEqualTo("")
    }

    @Test
    fun `given scan, when encoded, then duplicates are allowed`() {
        val o = obj(Wire.scan(listOf("180D")))
        assertThat(o["type"]?.jsonPrimitive?.content).isEqualTo("scan")
        assertThat(o["options"]?.jsonObject?.get("kCBScanOptionAllowDuplicates")?.jsonPrimitive?.boolean).isTrue()
    }

    @Test
    fun `given setNotify, connect, cancel, read, stopScan, then shapes match the bridge`() {
        assertThat(obj(Wire.setNotify("p", "c", true))["enabled"]?.jsonPrimitive?.boolean).isTrue()
        assertThat(obj(Wire.connect("p"))["id"]?.jsonPrimitive?.content).isEqualTo("p")
        assertThat(obj(Wire.cancel("p"))["type"]?.jsonPrimitive?.content).isEqualTo("cancel")
        assertThat(obj(Wire.read("p", "c"))["characteristicId"]?.jsonPrimitive?.content).isEqualTo("c")
        assertThat(obj(Wire.stopScan())["type"]?.jsonPrimitive?.content).isEqualTo("stopScan")
    }

    @Test
    fun `given didUpdateValue with isNotification, when decoded, then flag and bytes are typed`() {
        val m = Wire.decode("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"AQID","error":"","isNotification":true}""")
        assertThat(m).isInstanceOf(DidUpdateValue::class.java)
        m as DidUpdateValue
        assertThat(m.value).isEqualTo(byteArrayOf(1, 2, 3))
        assertThat(m.isNotification).isTrue()
        assertThat(m.error).isEmpty()
    }

    @Test
    fun `given didUpdateValue from a provider without the flag, then isNotification is null`() {
        val m = Wire.decode("""{"type":"didUpdateValue","id":"p","characteristicId":"c","value":"","error":"boom"}""") as DidUpdateValue
        assertThat(m.isNotification).isNull()
        assertThat(m.value).isEmpty()
        assertThat(m.error).isEqualTo("boom")
    }

    @Test
    fun `given didConnect with write limits, then limits are decoded and absent limits are null`() {
        val m = Wire.decode("""{"type":"didConnect","id":"p","maxWriteWithResponse":512,"maxWriteWithoutResponse":182}""") as DidConnect
        assertThat(m.maxWriteWithResponse).isEqualTo(512)
        assertThat(m.maxWriteWithoutResponse).isEqualTo(182)
        val bare = Wire.decode("""{"type":"didConnect","id":"p"}""") as DidConnect
        assertThat(bare.maxWriteWithResponse).isNull()
    }

    @Test
    fun `given connection and write replies, then they decode`() {
        assertThat(Wire.decode("""{"type":"didFailConnect","id":"p","error":"x"}""")).isEqualTo(DidFailConnect("p", "x"))
        assertThat(Wire.decode("""{"type":"didDisconnect","id":"p","error":"","timestamp":1.5,"isReconnecting":false}""")).isEqualTo(DidDisconnect("p", ""))
        assertThat(Wire.decode("""{"type":"didWriteValue","id":"p","characteristicId":"c","error":"","writeType":1}"""))
            .isEqualTo(DidWriteValue("p", "c", "", 1))
        assertThat(Wire.decode("""{"type":"didUpdateNotification","id":"p","characteristicId":"c","enabled":true,"error":""}"""))
            .isEqualTo(DidUpdateNotification("p", "c", true, ""))
        assertThat(Wire.decode("""{"type":"connectionRejected","retry":false}""")).isEqualTo(ConnectionRejected(false))
    }

    @Test
    fun `given didDiscover, then advertisement fields are typed`() {
        val line = """{"type":"didDiscover","id":"p","name":"PM5 1","rssi":-60,"adv":{"kCBAdvDataLocalName":"PM5 1",""" +
            """"kCBAdvDataServiceUUIDs":["CE060000-43E5-11E4-916C-0800200C9A66"],"kCBAdvDataManufacturerData":"AQID",""" +
            """"kCBAdvDataServiceData":{"180D":"BA=="},"kCBAdvDataIsConnectable":true}}"""
        val m = Wire.decode(line) as DidDiscover
        assertThat(m.rssi).isEqualTo(-60)
        assertThat(m.adv.localName).isEqualTo("PM5 1")
        assertThat(m.adv.serviceUuids).containsExactly("CE060000-43E5-11E4-916C-0800200C9A66")
        assertThat(m.adv.manufacturerData).isEqualTo(byteArrayOf(1, 2, 3))
        assertThat(m.adv.serviceData["180D"]).isEqualTo(byteArrayOf(4))
        assertThat(m.adv.connectable).isTrue()
    }

    @Test
    fun `given unknown or malformed lines, then they are Unknown and never throw`() {
        assertThat(Wire.decode("""{"type":"didModifyServices"}""")).isEqualTo(Unknown("didModifyServices"))
        assertThat(Wire.decode("not json")).isEqualTo(Unknown(""))
        assertThat(Wire.decode("""{"type":"didUpdateValue","id":"p"}""")).isEqualTo(Unknown("didUpdateValue"))
    }

    @Test
    fun `given discovery requests, then shapes match the bridge`() {
        val services = obj(Wire.discoverServices("p"))
        assertThat(services["type"]?.jsonPrimitive?.content).isEqualTo("discoverServices")
        assertThat(services["services"]?.jsonArray).isEmpty()
        val chars = obj(Wire.discoverCharacteristics("p", "s1"))
        assertThat(chars["serviceId"]?.jsonPrimitive?.content).isEqualTo("s1")
        assertThat(chars["characteristics"]?.jsonArray).isEmpty()
        assertThat(obj(Wire.discoverDescriptors("p", "c1"))["characteristicId"]?.jsonPrimitive?.content).isEqualTo("c1")
    }

    @Test
    fun `given discovery replies, then services, characteristics and descriptors decode with expanded uuids`() {
        val s = Wire.decode(
            """{"type":"didDiscoverServices","id":"p","services":[{"id":"s1","uuid":"180D","primary":true},{"id":"s2","uuid":"CE060020-43E5-11E4-916C-0800200C9A66"}],"error":""}""",
        ) as DidDiscoverServices
        assertThat(s.services).containsExactly(
            ServiceInfo("s1", "0000180d-0000-1000-8000-00805f9b34fb", true),
            ServiceInfo("s2", "ce060020-43e5-11e4-916c-0800200c9a66", false),
        ).inOrder()
        val c = Wire.decode(
            """{"type":"didDiscoverCharacteristics","id":"p","serviceId":"s1","characteristics":[{"id":"c1","uuid":"2A37","properties":18}],"error":"x"}""",
        ) as DidDiscoverCharacteristics
        assertThat(c.serviceId).isEqualTo("s1")
        assertThat(c.characteristics).containsExactly(CharacteristicInfo("c1", "00002a37-0000-1000-8000-00805f9b34fb", 18))
        assertThat(c.error).isEqualTo("x")
        val d = Wire.decode("""{"type":"didDiscoverDescriptors","id":"p","characteristicId":"c1","descriptors":[{"id":"d1","uuid":"2902"}],"error":""}""") as DidDiscoverDescriptors
        assertThat(d.descriptors).containsExactly(DescriptorInfo("d1", "00002902-0000-1000-8000-00805f9b34fb"))
    }
}
