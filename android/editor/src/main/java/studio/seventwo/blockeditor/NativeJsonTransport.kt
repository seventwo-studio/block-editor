package studio.seventwo.blockeditor

import android.util.JsonReader
import android.util.JsonToken
import android.util.JsonWriter
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.BufferedWriter
import java.io.ByteArrayInputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.util.ArrayDeque
import java.util.IdentityHashMap

/** The JNI byte-array boundary without a second, whole-packet UTF-16 string. */
internal object NativeJsonTransport {
    fun copy(value: JSONObject): JSONObject = copyTree(value) as JSONObject
    fun copy(value: JSONArray): JSONArray = copyTree(value) as JSONArray

    // Defensive DTO copies own every container. Immutable strings can be shared:
    // serializing/reparsing a 64 MB recovery solely to clone it doubles its text.
    private fun copyTree(value: Any): Any {
        val frames = ArrayDeque<CopyFrame>()
        val active = IdentityHashMap<Any, Boolean>()
        fun item(source: Any?): Any = when (source) {
            null, JSONObject.NULL -> JSONObject.NULL
            is JSONObject -> JSONObject().also { target ->
                check(active.put(source, true) == null) { "Cyclic JSON container" }
                frames.addLast(CopyFrame(source, target, source.keys()))
            }
            is JSONArray -> JSONArray().also { target ->
                check(active.put(source, true) == null) { "Cyclic JSON container" }
                frames.addLast(CopyFrame(source, target))
            }
            is String, is Boolean -> source
            is Number -> JSONTokener(JSONObject.numberToString(source)).nextValue()
            else -> source.toString()
        }
        val root = item(value)
        while (frames.isNotEmpty()) {
            val frame = frames.peekLast()
            val keys = frame.keys
            if (frame.source is JSONObject && keys != null && keys.hasNext()) {
                val key = keys.next()
                (frame.target as JSONObject).put(key, item(frame.source.get(key)))
            } else if (frame.source is JSONArray && frame.index < frame.source.length()) {
                (frame.target as JSONArray).put(item(frame.source.get(frame.index++)))
            } else {
                active.remove(frame.source)
                frames.removeLast()
            }
        }
        return root
    }

    fun encode(value: JSONObject): ByteArray {
        val counter = CountingSink()
        write(value, counter)
        val sink = FixedSink(ByteArray(counter.size))
        write(value, sink)
        check(sink.size == sink.bytes.size) { "JSON request changed while encoding" }
        return sink.bytes
    }

    // BufferedWriter keeps JsonWriter's character-at-a-time string escaping cheap
    // and bounds conversion scratch space. Closing also emits any pending surrogate.
    private fun write(value: JSONObject, sink: OutputStream) {
        JsonWriter(BufferedWriter(OutputStreamWriter(sink, Charsets.UTF_8), 8192)).use { writer ->
            val frames = ArrayDeque<WriteFrame>()
            val active = IdentityHashMap<Any, Boolean>()
            fun emit(item: Any?) {
                when (item) {
                    null, JSONObject.NULL -> writer.nullValue()
                    is JSONObject -> {
                        check(active.put(item, true) == null) { "Cyclic JSON container" }
                        writer.beginObject()
                        frames.addLast(ObjectWriteFrame(item, item.keys()))
                    }
                    is JSONArray -> {
                        check(active.put(item, true) == null) { "Cyclic JSON container" }
                        writer.beginArray()
                        frames.addLast(ArrayWriteFrame(item))
                    }
                    is String -> writer.value(item)
                    is Boolean -> writer.value(item)
                    is Number -> writer.value(WireNumber(item))
                    else -> writer.value(item.toString()) // JSONObject's existing fallback.
                }
            }
            emit(value)
            while (frames.isNotEmpty()) {
                when (val frame = frames.peekLast()) {
                    is ObjectWriteFrame -> if (frame.keys.hasNext()) {
                        val key = frame.keys.next()
                        writer.name(key)
                        emit(frame.value.get(key))
                    } else {
                        writer.endObject()
                        active.remove(frame.value)
                        frames.removeLast()
                    }
                    is ArrayWriteFrame -> if (frame.index < frame.value.length()) {
                        emit(frame.value.get(frame.index++))
                    } else {
                        writer.endArray()
                        active.remove(frame.value)
                        frames.removeLast()
                    }
                }
            }
        }
    }

    fun decode(bytes: ByteArray): JSONObject {
        JsonReader(InputStreamReader(ByteArrayInputStream(bytes), Charsets.UTF_8)).use { reader ->
            check(reader.peek() == JsonToken.BEGIN_OBJECT) { "Swift response is not an object" }
            val root = JSONObject()
            reader.beginObject()
            val frames = ArrayDeque<Any>()
            frames.addLast(root)
            while (frames.isNotEmpty()) {
                val parent = frames.peekLast()
                if (!reader.hasNext()) {
                    if (parent is JSONObject) reader.endObject() else reader.endArray()
                    frames.removeLast()
                    continue
                }
                val key = if (parent is JSONObject) reader.nextName() else null
                val value: Any = when (reader.peek()) {
                    JsonToken.BEGIN_OBJECT -> JSONObject().also { reader.beginObject() }
                    JsonToken.BEGIN_ARRAY -> JSONArray().also { reader.beginArray() }
                    JsonToken.STRING -> reader.nextString()
                    JsonToken.NUMBER -> number(reader.nextString())
                    JsonToken.BOOLEAN -> reader.nextBoolean()
                    JsonToken.NULL -> { reader.nextNull(); JSONObject.NULL }
                    else -> error("Unexpected Swift JSON token")
                }
                if (parent is JSONObject) parent.put(checkNotNull(key), value)
                else (parent as JSONArray).put(value)
                if (value is JSONObject || value is JSONArray) frames.addLast(value)
            }
            check(reader.peek() == JsonToken.END_DOCUMENT) { "Trailing Swift JSON response" }
            return root
        }
    }

    // Android JSONTokener prefers Int, then Long, then Double. Reading the token
    // as a string avoids nextDouble's precision loss for integral IDs > 2^53.
    private fun number(token: String): Number {
        if (!token.contains('.')) {
            token.toLongOrNull()?.let { value ->
                return if (value in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) value.toInt() else value
            }
        }
        return token.toDouble()
    }

    private sealed interface WriteFrame
    private class CopyFrame(val source: Any, val target: Any, val keys: Iterator<String>? = null, var index: Int = 0)
    private class ObjectWriteFrame(val value: JSONObject, val keys: Iterator<String>) : WriteFrame
    private class ArrayWriteFrame(val value: JSONArray, var index: Int = 0) : WriteFrame

    // JsonWriter normally uses Number.toString(). Keep JSONObject's canonical
    // spelling (including negative zero and integral-valued doubles) instead.
    private class WireNumber(private val value: Number) : Number() {
        private val token = JSONObject.numberToString(value)
        override fun toString() = token
        override fun toByte() = value.toByte()
        override fun toShort() = value.toShort()
        override fun toInt() = value.toInt()
        override fun toLong() = value.toLong()
        override fun toFloat() = value.toFloat()
        override fun toDouble() = value.toDouble()
    }

    private class CountingSink : OutputStream() {
        var size = 0
            private set
        override fun write(value: Int) { size = Math.addExact(size, 1) }
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            size = Math.addExact(size, length)
        }
    }

    private class FixedSink(val bytes: ByteArray) : OutputStream() {
        var size = 0
            private set
        override fun write(value: Int) {
            check(size < bytes.size) { "JSON request changed while encoding" }
            bytes[size++] = value.toByte()
        }
        override fun write(source: ByteArray, offset: Int, length: Int) {
            check(length <= bytes.size - size) { "JSON request changed while encoding" }
            source.copyInto(bytes, size, offset, offset + length)
            size += length
        }
    }
}
