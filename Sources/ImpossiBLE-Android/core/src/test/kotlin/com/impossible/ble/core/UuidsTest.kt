package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class UuidsTest {

    @Test
    fun `given a 16-bit string, then it expands onto the base uuid in lower case`() {
        assertThat(Uuids.expand("180D")).isEqualTo("0000180d-0000-1000-8000-00805f9b34fb")
    }

    @Test
    fun `given a 32-bit string, then it expands onto the base uuid`() {
        assertThat(Uuids.expand("0000180D")).isEqualTo("0000180d-0000-1000-8000-00805f9b34fb")
        assertThat(Uuids.expand("CE060020")).isEqualTo("ce060020-0000-1000-8000-00805f9b34fb")
    }

    @Test
    fun `given a 128-bit string, then it is only lower cased`() {
        assertThat(Uuids.expand("CE060022-43E5-11E4-916C-0800200C9A66")).isEqualTo("ce060022-43e5-11e4-916c-0800200c9a66")
    }

    @Test
    fun `given short and long forms of the same uuid, then they compare equal after expansion`() {
        assertThat(Uuids.expand("180d")).isEqualTo(Uuids.expand("0000180D-0000-1000-8000-00805F9B34FB"))
    }

    @Test
    fun `given a peripheral uuid, then the mac is stable locally administered and formatted`() {
        val a = Uuids.mac("E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")
        assertThat(Uuids.mac("e2c56db5-dffb-48d2-b060-d0f5a71096e0")).isEqualTo(a)
        assertThat(a).matches("02(:[0-9A-F]{2}){5}")
        assertThat(Uuids.mac("00000000-0000-0000-0000-000000000001")).isNotEqualTo(a)
    }

    @Test
    fun `given an identity, then address and uuid map both ways`() {
        val id = Identity()
        val address = id.addressFor("E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")
        assertThat(id.addressFor("E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")).isEqualTo(address)
        assertThat(id.uuidFor(address)).isEqualTo("E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")
        assertThat(id.uuidFor("02:00:00:00:00:00")).isNull()
    }
}
