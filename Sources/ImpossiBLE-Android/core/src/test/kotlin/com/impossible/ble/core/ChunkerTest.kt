package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class ChunkerTest {

    private fun sizes(length: Int, limit: Int) = Chunker.split(ByteArray(length), limit).map { it.size }

    @Test
    fun `given payload at exactly the limit, then one chunk`() {
        assertThat(sizes(182, 182)).containsExactly(182)
    }

    @Test
    fun `given payload one over the limit, then a full chunk and a single byte`() {
        assertThat(sizes(183, 182)).containsExactly(182, 1).inOrder()
    }

    @Test
    fun `given payload of twice the limit, then two full chunks and no empty tail`() {
        assertThat(sizes(364, 182)).containsExactly(182, 182).inOrder()
    }

    @Test
    fun `given a 432 byte firmware chunk, then it splits by the reported limit`() {
        assertThat(sizes(432, 182)).containsExactly(182, 182, 68).inOrder()
        assertThat(sizes(432, 512)).containsExactly(432)
    }

    @Test
    fun `given a 928 byte firmware chunk, then it splits by the reported limit`() {
        assertThat(sizes(928, 182)).containsExactly(182, 182, 182, 182, 182, 18).inOrder()
        assertThat(sizes(928, 20)).hasSize(47)
    }

    @Test
    fun `given an empty payload, then one empty chunk is produced`() {
        assertThat(sizes(0, 20)).containsExactly(0)
    }

    @Test
    fun `given chunks, then concatenation restores the payload in order`() {
        val data = ByteArray(1000) { it.toByte() }
        assertThat(Chunker.split(data, 182).reduce { a, b -> a + b }).isEqualTo(data)
    }

    @Test
    fun `given a non positive limit, then it is rejected`() {
        assertThrows(IllegalArgumentException::class.java) { Chunker.split(ByteArray(1), 0) }
    }
}
