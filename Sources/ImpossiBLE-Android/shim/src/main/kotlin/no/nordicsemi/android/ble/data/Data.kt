package no.nordicsemi.android.ble.data

import kotlin.math.pow

class Data(private val bytes: ByteArray? = null) {

    val value: ByteArray? get() = bytes

    fun size(): Int = bytes?.size ?: 0

    fun getByte(offset: Int): Byte? = if (offset in 0 until size()) bytes?.get(offset) else null

    fun getStringValue(offset: Int): String? = bytes?.takeIf { offset in 0..it.size }?.let { String(it, offset, it.size - offset, Charsets.UTF_8) }

    fun getIntValue(format: Int, offset: Int): Int? = readRaw(format, offset)?.toInt()

    fun getLongValue(format: Int, offset: Int): Long? = readRaw(format, offset)

    fun getFloatValue(format: Int, offset: Int): Float? {
        val unsigned = (format and (BIG_ENDIAN or TYPE_LEN_MASK)) or UNSIGNED_TYPE
        val raw = readRaw(unsigned, offset)?.toInt() ?: return null
        return when (format) {
            FORMAT_SFLOAT -> scaled(raw and SFLOAT_MANTISSA_MASK, SFLOAT_MANTISSA_BITS, raw shr SFLOAT_MANTISSA_BITS, SFLOAT_EXPONENT_BITS)
            FORMAT_FLOAT -> scaled(raw and FLOAT_MANTISSA_MASK, FLOAT_MANTISSA_BITS, raw ushr FLOAT_MANTISSA_BITS, Byte.SIZE_BITS)
            else -> null
        }
    }

    override fun toString(): String = bytes?.joinToString("-", prefix = "(0x) ") { "%02X".format(java.util.Locale.ROOT, it) } ?: "null"

    private fun readRaw(format: Int, offset: Int): Long? {
        val data = bytes ?: return null
        val length = typeLen(format)
        if (offset < 0 || offset + length > data.size) return null
        var raw = 0L
        for (i in 0 until length) {
            val index = if (format and BIG_ENDIAN != 0) offset + i else offset + length - 1 - i
            raw = (raw shl Byte.SIZE_BITS) or (data[index].toLong() and BYTE_MASK)
        }
        val isSigned = format and TYPE_MASK == SIGNED_TYPE
        return if (isSigned) signed(raw, length * Byte.SIZE_BITS) else raw
    }

    private fun scaled(mantissa: Int, mantissaBits: Int, exponent: Int, exponentBits: Int): Float {
        val exponentMask = (1 shl exponentBits) - 1
        return (signed(mantissa, mantissaBits) * 10.0.pow(signed(exponent and exponentMask, exponentBits))).toFloat()
    }

    private fun signed(raw: Int, bits: Int): Int = if (raw and (1 shl (bits - 1)) != 0) raw - (1 shl bits) else raw

    private fun signed(raw: Long, bits: Int): Long = if (raw and (1L shl (bits - 1)) != 0L) raw - (1L shl bits) else raw

    companion object {
        const val FORMAT_UINT8 = 0x11
        const val FORMAT_UINT16 = 0x12
        const val FORMAT_UINT16_LE = 0x12
        const val FORMAT_UINT16_BE = 0x112
        const val FORMAT_UINT24 = 0x13
        const val FORMAT_UINT24_LE = 0x13
        const val FORMAT_UINT24_BE = 0x113
        const val FORMAT_UINT32 = 0x14
        const val FORMAT_UINT32_LE = 0x14
        const val FORMAT_UINT32_BE = 0x114
        const val FORMAT_SINT8 = 0x21
        const val FORMAT_SINT16 = 0x22
        const val FORMAT_SINT16_LE = 0x22
        const val FORMAT_SINT16_BE = 0x122
        const val FORMAT_SINT24 = 0x23
        const val FORMAT_SINT24_LE = 0x23
        const val FORMAT_SINT24_BE = 0x123
        const val FORMAT_SINT32 = 0x24
        const val FORMAT_SINT32_LE = 0x24
        const val FORMAT_SINT32_BE = 0x124
        const val FORMAT_SFLOAT = 0x32
        const val FORMAT_FLOAT = 0x34

        private const val BIG_ENDIAN = 0x100
        private const val TYPE_LEN_MASK = 0xF
        private const val TYPE_MASK = 0xF0
        private const val SIGNED_TYPE = 0x20
        private const val UNSIGNED_TYPE = 0x10
        private const val BYTE_MASK = 0xFFL
        private const val SFLOAT_MANTISSA_BITS = 12
        private const val SFLOAT_EXPONENT_BITS = 4
        private const val SFLOAT_MANTISSA_MASK = 0x0FFF
        private const val FLOAT_MANTISSA_BITS = 24
        private const val FLOAT_MANTISSA_MASK = 0x00FFFFFF

        fun from(text: String): Data = Data(text.toByteArray(Charsets.UTF_8))

        fun opCode(code: Byte): Data = Data(byteArrayOf(code))

        fun opCode(code: Byte, parameter: Byte): Data = Data(byteArrayOf(code, parameter))

        fun typeLen(format: Int): Int = format and TYPE_LEN_MASK
    }
}
