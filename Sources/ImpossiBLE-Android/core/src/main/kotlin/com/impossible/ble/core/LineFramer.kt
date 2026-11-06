package com.impossible.ble.core

import java.io.ByteArrayOutputStream
import java.io.IOException

class LineTooLongException(maxLine: Int) : IOException("line exceeds $maxLine bytes")

class LineFramer(private val maxLine: Int = DEFAULT_MAX_LINE) {
    private val pending = ByteArrayOutputStream()

    fun feed(bytes: ByteArray, length: Int = bytes.size): List<String> {
        val lines = mutableListOf<String>()
        for (i in 0 until length) {
            val b = bytes[i]
            if (b == NEWLINE) {
                if (pending.size() > 0) lines += pending.toString(Charsets.UTF_8.name())
                pending.reset()
            } else {
                if (pending.size() >= maxLine) throw LineTooLongException(maxLine)
                pending.write(b.toInt())
            }
        }
        return lines
    }

    private companion object {
        const val NEWLINE = '\n'.code.toByte()
        const val DEFAULT_MAX_LINE = 4 * 1024 * 1024
    }
}
