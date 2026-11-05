package com.impossible.ble.shim

import com.google.common.truth.Truth.assertThat
import no.nordicsemi.android.ble.data.Data
import org.junit.Test

class DataTest {

    private val data = Data(byteArrayOf(0x01, 0x02, 0x03, 0xFF.toByte()))

    @Test
    fun `given bytes, then value and size are exposed`() {
        assertThat(data.value).isEqualTo(byteArrayOf(1, 2, 3, -1))
        assertThat(data.size()).isEqualTo(4)
    }

    @Test
    fun `given unsigned and signed formats, then little endian and big endian values decode`() {
        assertThat(data.getIntValue(Data.FORMAT_UINT8, 3)).isEqualTo(255)
        assertThat(data.getIntValue(Data.FORMAT_SINT8, 3)).isEqualTo(-1)
        assertThat(data.getIntValue(Data.FORMAT_UINT16_LE, 0)).isEqualTo(0x0201)
        assertThat(data.getIntValue(Data.FORMAT_UINT16_BE, 0)).isEqualTo(0x0102)
        assertThat(data.getIntValue(Data.FORMAT_UINT24_LE, 0)).isEqualTo(0x030201)
        assertThat(data.getIntValue(Data.FORMAT_UINT32_LE, 0)).isEqualTo(-0xFCFDFF)
        assertThat(data.getLongValue(Data.FORMAT_UINT32_LE, 0)).isEqualTo(0xFF030201L)
        assertThat(data.getIntValue(Data.FORMAT_SINT16_LE, 2)).isEqualTo(-253)
    }

    @Test
    fun `given an offset past the end, then values are null`() {
        assertThat(data.getIntValue(Data.FORMAT_UINT16_LE, 3)).isNull()
        assertThat(data.getByte(4)).isNull()
        assertThat(data.getByte(1)).isEqualTo(2.toByte())
    }

    @Test
    fun `given text, then string value decodes from the offset`() {
        assertThat(Data.from("PM5 123").getStringValue(4)).isEqualTo("123")
        assertThat(Data().size()).isEqualTo(0)
    }

    @Test
    fun `given an sfloat, then it decodes mantissa and exponent`() {
        val sfloat = Data(byteArrayOf(0x64, 0xF0.toByte()))
        assertThat(sfloat.getFloatValue(Data.FORMAT_SFLOAT, 0)).isEqualTo(10.0f)
    }
}
