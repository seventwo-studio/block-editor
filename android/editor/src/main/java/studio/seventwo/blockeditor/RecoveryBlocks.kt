package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject

/** Original root/toggle blocks for an explicit host repair, not a merged preview. */
data class RecoveryBlock(val identity: NodeIdentity, val key: String, val label: String)

fun MergeRecovery.originalBlocksForWrapping(): List<RecoveryBlock> {
    val blocks = linkedMapOf<String, Pair<JSONObject, JSONObject>>()
    fun register(value: JSONObject, identity: JSONObject) {
        val pending = ArrayDeque<Pair<JSONObject, JSONObject>>()
        pending.add(value to identity)
        while (pending.isNotEmpty()) {
            val (block, origin) = pending.removeLast()
            blocks[identityKey(origin)] = block to origin
            if (block.optString("type") != "toggle") continue
            val children = block.optJSONArray("children") ?: continue
            for (index in 0 until children.length()) {
                val child = children.getJSONObject(index)
                val next = JSONObject(origin.toString())
                val kind = next.keys().next()
                val path = next.getJSONObject(kind).getJSONArray("path")
                path.put("children").put(child.getString("id"))
                pending.add(child to next)
            }
        }
    }
    val original = batch
    val baseline = original.getJSONObject("baseline").getJSONArray("blocks")
    for (index in 0 until baseline.length()) {
        val block = baseline.getJSONObject(index)
        register(block, JSONObject().put("baseline", JSONObject().put("blockID", block.getString("id")).put("path", JSONArray())))
    }
    val changes = original.getJSONArray("changes") // Engine exports a canonical change order.
    for (index in 0 until changes.length()) {
        val edits = changes.getJSONObject(index).getJSONObject("body").optJSONObject("edit")?.optJSONArray("_0") ?: continue
        for (position in 0 until edits.length()) {
            val inserted = edits.getJSONObject(position).optJSONObject("insertNode") ?: continue
            val collection = inserted.getJSONObject("collection")
            val owner = collection.optJSONObject("owner")?.let { blocks[identityKey(it)]?.first }
            if (collection.optString("field") == "blocks" || (collection.optString("field") == "children" && owner?.optString("type") == "toggle"))
                register(inserted.getJSONObject("value"), inserted.getJSONObject("identity"))
        }
    }
    return blocks.map { (key, entry) ->
        val (block, identity) = entry
        val field = if (block.optString("type") == "toggle") "summary" else "content"
        val text = plainText(block.optJSONArray(field)).ifEmpty { block.optString("id", "Untitled") }
        val title = text.substring(0, text.offsetByCodePoints(0, minOf(60, text.codePointCount(0, text.length))))
        RecoveryBlock(NodeIdentity(identity), key, "Original ${block.optString("type", "block")}: $title")
    }.sortedBy { it.key }
}

private fun identityKey(value: Any?): String = when (value) {
    is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + identityKey(value.get(it)) }
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { identityKey(value.get(it)) }
    is String -> JSONObject.quote(value)
    else -> value.toString()
}
