package studio.seventwo.blockeditor

/** Shared Swift inspection of original UTF-8; no session mutation or activation.
 * Invoke on the native editor executor, like other JNI calls. Each result owns
 * its decoded containers. The existing 64 MB byte budget is unchanged. */
object ModernWireJSON {
    fun inspect(bytes: ByteArray): Any = NativeEngine.inspectJSON(bytes)
}
