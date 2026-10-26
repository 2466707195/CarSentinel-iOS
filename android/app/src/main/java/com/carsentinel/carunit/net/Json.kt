package com.carsentinel.carunit.net

/**
 * 手写 JSON：只支持扁平对象 + 一层「扁平对象数组」。
 * 不引 Moshi / Gson / kotlinx.serialization。
 */
object Json {

    /** 扁平 JSON 对象，保持插入顺序（协议里字段顺序稳定，便于肉眼比对） */
    class Obj {
        private val map = LinkedHashMap<String, Any?>()

        fun put(key: String, value: String?): Obj {
            map[key] = value
            return this
        }

        fun put(key: String, value: Int): Obj {
            map[key] = value
            return this
        }

        fun put(key: String, value: Long): Obj {
            map[key] = value
            return this
        }

        fun put(key: String, value: Double): Obj {
            map[key] = value
            return this
        }

        fun put(key: String, value: Boolean): Obj {
            map[key] = value
            return this
        }

        fun put(key: String, value: List<Obj>): Obj {
            map[key] = ArrayList<Any?>(value)
            return this
        }

        /** 字符串数组，例如 caps */
        fun put(key: String, value: List<String>): Obj {
            map[key] = ArrayList<Any?>(value)
            return this
        }

        /**
         * 摄像头数组 —— announce / welcome / cameras / camera_state 都要用。
         * 字段名与顺序严格按 PROTOCOL.md §2.1：id / name / pos / w / h。
         *
         * ⚠️ 方法名必须叫 putCameras 而不是 put：Kotlin 的泛型在 JVM 上会擦除，
         *    `put(String, List<Obj>)` / `put(String, List<String>)` /
         *    `put(String, List<CameraInfo>)` 编译后全是
         *    `put(String, Ljava/util/List;)`，直接报 Platform declaration clash。
         *    换名字是唯一解（加 @JvmName 对这个场景也没用，因为是同一编译单元内的重载）。
         */
        fun putCameras(key: String, value: List<CameraInfo>): Obj {
            map[key] = ArrayList<Any?>(value.map { c ->
                Obj()
                    .put("id", c.id)
                    .put("name", c.name)
                    .put("pos", c.pos)
                    .put("w", c.w)
                    .put("h", c.h)
            })
            return this
        }

        internal fun putRaw(key: String, value: Any?): Obj {
            map[key] = value
            return this
        }

        internal fun entries(): List<Pair<String, Any?>> = ArrayList<Pair<String, Any?>>(map.size).also { out ->
            for ((k, v) in map) out.add(Pair(k, v))
        }

        fun has(key: String): Boolean = map.containsKey(key)

        fun getString(key: String): String? = map[key] as? String

        fun getInt(key: String): Int? = when (val v = map[key]) {
            is Int -> v
            is Long -> v.toInt()
            is Double -> v.toInt()
            is String -> v.trim().toIntOrNull()
            else -> null
        }

        fun getLong(key: String): Long? = when (val v = map[key]) {
            is Long -> v
            is Int -> v.toLong()
            is Double -> v.toLong()
            is String -> v.trim().toLongOrNull()
            else -> null
        }

        fun getDouble(key: String): Double? = when (val v = map[key]) {
            is Double -> v
            is Int -> v.toDouble()
            is Long -> v.toDouble()
            is String -> v.trim().toDoubleOrNull()
            else -> null
        }

        fun getBool(key: String): Boolean? = when (val v = map[key]) {
            is Boolean -> v
            is String -> v.equals("true", ignoreCase = true)
            else -> null
        }

        fun getArray(key: String): List<Obj> {
            @Suppress("UNCHECKED_CAST")
            return (map[key] as? List<Any?>)?.filterIsInstance<Obj>() ?: emptyList()
        }

        override fun toString(): String = encode(this)
    }

    // ---------- 编码 ----------

    fun encode(o: Obj): String {
        val sb = StringBuilder(256)
        writeObj(sb, o)
        return sb.toString()
    }

    private fun writeObj(sb: StringBuilder, o: Obj) {
        sb.append('{')
        var first = true
        for ((k, v) in o.entries()) {
            if (!first) sb.append(',')
            first = false
            writeString(sb, k)
            sb.append(':')
            writeValue(sb, v)
        }
        sb.append('}')
    }

    private fun writeValue(sb: StringBuilder, v: Any?) {
        when (v) {
            null -> sb.append("null")
            is String -> writeString(sb, v)
            is Int, is Long, is Short, is Byte -> sb.append(v.toString())
            is Double -> {
                if (v.isNaN() || v.isInfinite()) sb.append('0') else sb.append(v.toString())
            }
            is Float -> {
                val d = v.toDouble()
                if (d.isNaN() || d.isInfinite()) sb.append('0') else sb.append(d.toString())
            }
            is Boolean -> sb.append(if (v) "true" else "false")
            is List<*> -> {
                sb.append('[')
                var first = true
                for (item in v) {
                    if (!first) sb.append(',')
                    first = false
                    writeValue(sb, item)
                }
                sb.append(']')
            }
            is Obj -> writeObj(sb, v)
            else -> writeString(sb, v.toString())
        }
    }

    private fun writeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\b' -> sb.append("\\b")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> {
                    if (c < ' ' || c in '\u007F'..'\u009F') {
                        sb.append("\\u")
                        val hex = Integer.toHexString(c.code)
                        for (i in hex.length until 4) sb.append('0')
                        sb.append(hex)
                    } else {
                        sb.append(c)
                    }
                }
            }
        }
        sb.append('"')
    }

    // ---------- 解码 ----------

    class ParseException(msg: String) : Exception(msg)

    fun parse(text: String): Obj {
        val p = Parser(text)
        p.skipWs()
        val v = p.parseValue()
        p.skipWs()
        if (!p.eof()) throw ParseException("trailing garbage at ${p.pos}")
        return v as? Obj ?: throw ParseException("root is not an object")
    }

    private class Parser(private val s: String) {
        var pos = 0

        fun eof(): Boolean = pos >= s.length

        fun skipWs() {
            while (pos < s.length) {
                val c = s[pos]
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') pos++ else break
            }
        }

        fun parseValue(): Any? {
            skipWs()
            if (eof()) throw ParseException("unexpected end")
            return when (s[pos]) {
                '{' -> parseObj()
                '[' -> parseArray()
                '"' -> parseString()
                't', 'f' -> parseBool()
                'n' -> parseNull()
                else -> parseNumber()
            }
        }

        private fun parseObj(): Obj {
            expect('{')
            val o = Obj()
            skipWs()
            if (peek() == '}') {
                pos++
                return o
            }
            while (true) {
                skipWs()
                val key = parseString()
                skipWs()
                expect(':')
                val v = parseValue()
                o.putRaw(key, v)
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    '}' -> {
                        pos++
                        return o
                    }
                    else -> throw ParseException("expected , or } at $pos")
                }
            }
        }

        private fun parseArray(): List<Any?> {
            expect('[')
            val list = ArrayList<Any?>()
            skipWs()
            if (peek() == ']') {
                pos++
                return list
            }
            while (true) {
                list.add(parseValue())
                skipWs()
                when (peek()) {
                    ',' -> pos++
                    ']' -> {
                        pos++
                        return list
                    }
                    else -> throw ParseException("expected , or ] at $pos")
                }
            }
        }

        private fun parseString(): String {
            expect('"')
            val sb = StringBuilder()
            while (pos < s.length) {
                val c = s[pos++]
                when (c) {
                    '"' -> return sb.toString()
                    '\\' -> {
                        if (eof()) throw ParseException("dangling escape")
                        when (val e = s[pos++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (pos + 4 > s.length) throw ParseException("short \\u")
                                val hex = s.substring(pos, pos + 4)
                                pos += 4
                                sb.append(hex.toInt(16).toChar())
                            }
                            else -> throw ParseException("bad escape \\$e")
                        }
                    }
                    else -> sb.append(c)
                }
            }
            throw ParseException("unterminated string")
        }

        private fun parseBool(): Any {
            if (s.startsWith("true", pos)) {
                pos += 4
                return true
            }
            if (s.startsWith("false", pos)) {
                pos += 5
                return false
            }
            throw ParseException("bad literal at $pos")
        }

        private fun parseNull(): Any? {
            if (s.startsWith("null", pos)) {
                pos += 4
                return null
            }
            throw ParseException("bad literal at $pos")
        }

        private fun parseNumber(): Any {
            val start = pos
            if (peek() == '-' || peek() == '+') pos++
            var isDouble = false
            while (pos < s.length) {
                val c = s[pos]
                if (c in '0'..'9') {
                    pos++
                } else if (c == '.' || c == 'e' || c == 'E') {
                    isDouble = true
                    pos++
                } else if (c == '-' || c == '+') {
                    pos++
                } else {
                    break
                }
            }
            if (pos == start) throw ParseException("bad value at $pos")
            val raw = s.substring(start, pos)
            return if (isDouble) {
                raw.toDoubleOrNull() ?: throw ParseException("bad number $raw")
            } else {
                raw.toLongOrNull() ?: raw.toDoubleOrNull() ?: throw ParseException("bad number $raw")
            }
        }

        private fun peek(): Char = if (pos < s.length) s[pos] else '\u0000'

        private fun expect(c: Char) {
            if (peek() != c) throw ParseException("expected '$c' at $pos")
            pos++
        }
    }
}
