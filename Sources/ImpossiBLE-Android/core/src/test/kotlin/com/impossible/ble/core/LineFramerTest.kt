package com.impossible.ble.core

import com.google.common.truth.Truth.assertThat
import org.junit.Assert.assertThrows
import org.junit.Test

class LineFramerTest {

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)

    @Test
    fun `given a partial line, when the rest arrives, then one line is emitted`() {
        val f = LineFramer()
        assertThat(f.feed(bytes("{\"a\":"))).isEmpty()
        assertThat(f.feed(bytes("1}\n"))).containsExactly("{\"a\":1}")
    }

    @Test
    fun `given merged lines in one chunk, then all are emitted in order and the tail is kept`() {
        val f = LineFramer()
        assertThat(f.feed(bytes("a\nb\nc"))).containsExactly("a", "b").inOrder()
        assertThat(f.feed(bytes("d\n"))).containsExactly("cd")
    }

    @Test
    fun `given a multibyte character split across chunks, then it is decoded intact`() {
        val whole = bytes("zażółć\n")
        val f = LineFramer()
        assertThat(f.feed(whole.copyOfRange(0, 3))).isEmpty()
        assertThat(f.feed(whole.copyOfRange(3, whole.size))).containsExactly("zażółć")
    }

    @Test
    fun `given a length argument, then bytes past it are ignored`() {
        assertThat(LineFramer().feed(bytes("ab\ncd\n"), 3)).containsExactly("ab")
    }

    @Test
    fun `given empty lines, then they are skipped`() {
        assertThat(LineFramer().feed(bytes("\n\na\n"))).containsExactly("a")
    }

    @Test
    fun `given a line longer than the cap, then framing fails`() {
        val f = LineFramer(maxLine = 8)
        assertThat(f.feed(bytes("12345678"))).isEmpty()
        assertThrows(LineTooLongException::class.java) { f.feed(bytes("9")) }
    }
}
