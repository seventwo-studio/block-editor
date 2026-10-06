package studio.seventwo.blockeditor

import org.json.JSONArray
import org.json.JSONObject

/** Owned wire data. Exports and nested values are defensive copies, including consumer extensions. */
open class ModernValue internal constructor(value: JSONObject) {
    private val data = NativeJsonTransport.copy(value)
    fun export(): JSONObject = NativeJsonTransport.copy(data)
    protected fun string(key: String): String = data.getString(key)
    protected fun optionalString(key: String): String? = if (data.has(key) && !data.isNull(key)) data.getString(key) else null
    protected fun number(key: String): Long = data.getLong(key)
    protected fun boolean(key: String): Boolean = data.getBoolean(key)
    protected fun objectValue(key: String): JSONObject = NativeJsonTransport.copy(data.getJSONObject(key))
    protected fun optionalObject(key: String): JSONObject? = data.optJSONObject(key)?.let { NativeJsonTransport.copy(it) }
    protected fun arrayValue(key: String): JSONArray = NativeJsonTransport.copy(data.getJSONArray(key))
}
class ModernPayload private constructor(value: JSONObject) : ModernValue(value) {
    companion object { fun restore(value: JSONObject) = ModernPayload(value) }
}
internal fun modernObject(vararg entries: Pair<String, Any?>): JSONObject = JSONObject().also { result ->
    entries.forEach { (key, value) -> result.put(key, when (value) {
        is ModernValue -> value.export()
        null -> JSONObject.NULL
        else -> value
    }) }
}
internal fun modernArray(values: Collection<ModernValue>) = JSONArray(values.map { it.export() })

data class ModernChangeID(val actor: String, val counter: Long) {
    internal fun wire() = modernObject("actor" to actor, "counter" to counter)
    companion object { internal fun read(value: JSONObject) = ModernChangeID(value.getString("actor"), value.getLong("counter")) }
}
data class ModernElementID(val change: ModernChangeID, val index: Int) {
    internal fun wire() = modernObject("change" to change.wire(), "index" to index)
}
class ModernNodeID private constructor(value: JSONObject) : ModernValue(value) {
    companion object {
        fun document(documentID: String) = ModernNodeID(modernObject("document" to modernObject("documentID" to documentID)))
        fun baseline(blockID: String, path: List<String> = emptyList()) = ModernNodeID(modernObject("baseline" to modernObject("blockID" to blockID, "path" to JSONArray(path))))
        fun inserted(creation: ModernElementID, path: List<String> = emptyList()) = ModernNodeID(modernObject("inserted" to modernObject("creation" to creation.wire(), "path" to JSONArray(path))))
        fun restore(value: JSONObject) = ModernNodeID(value)
    }
}
data class ModernField(val node: ModernNodeID, val name: String) { internal fun wire() = modernObject("node" to node, "name" to name) }
enum class ModernCollectionField(val wireValue: String) { CHILDREN("children"), COLUMNS("columns"), ITEMS("items"), ROWS("rows"), CELLS("cells") }
sealed class ModernCollection {
    companion object {
        fun restore(value: JSONObject): ModernCollection = if (value.getString("field") == "blocks") Blocks else Owned(ModernNodeID.restore(value.getJSONObject("owner")), ModernCollectionField.entries.first { it.wireValue == value.getString("field") })
    }
    internal abstract fun wire(): JSONObject
    data object Blocks : ModernCollection() { override fun wire() = modernObject("field" to "blocks") }
    data class Owned(val owner: ModernNodeID, val field: ModernCollectionField) : ModernCollection() {
        override fun wire() = modernObject("owner" to owner, "field" to field.wireValue)
    }
}
class ModernPosition internal constructor(value: JSONObject) : ModernValue(value) {
    val documentID get() = string("documentID")
    val epoch get() = string("epoch")
    companion object { fun restore(value: JSONObject) = ModernPosition(value) }
}
class ModernRange(start: ModernPosition, end: ModernPosition) : ModernValue(modernObject("start" to start, "end" to end))
class ModernTextRange internal constructor(value: JSONObject) : ModernValue(value) {
    val start get() = ModernPosition(objectValue("start"))
    val end get() = ModernPosition(objectValue("end"))
    companion object { fun restore(value: JSONObject) = ModernTextRange(value) }
}
class ModernBoundary internal constructor(value: JSONObject) : ModernValue(value) {
    companion object { fun restore(value: JSONObject) = ModernBoundary(value) }
}
class ModernNodes internal constructor(value: JSONObject) : ModernValue(value) {
    val nodes: List<ModernNodeID> get() = arrayValue("nodes").let { values -> (0 until values.length()).map { ModernNodeID.restore(values.getJSONObject(it)) } }
    companion object { fun restore(value: JSONObject) = ModernNodes(value) }
}
class ModernDeleteTarget(nodes: ModernNodes? = null, ranges: List<ModernTextRange> = emptyList()) : ModernValue(
    modernObject("ranges" to modernArray(ranges)).also { nodes?.let { nodes -> it.put("nodes", nodes.export()) } })
class ModernFocusIntent private constructor(value: JSONObject) : ModernValue(value) {
    companion object {
        fun text(position: ModernPosition) = ModernFocusIntent(modernObject("text" to modernObject("_0" to position)))
        fun nodes(nodes: ModernNodes) = ModernFocusIntent(modernObject("nodes" to modernObject("_0" to nodes)))
        fun insertion(boundary: ModernBoundary) = ModernFocusIntent(modernObject("insertion" to modernObject("_0" to boundary)))
        internal fun read(value: JSONObject) = ModernFocusIntent(value)
    }
}
class ModernSelectionIntent private constructor(value: JSONObject) : ModernValue(value) {
    companion object {
        fun text(range: ModernRange) = ModernSelectionIntent(modernObject("text" to modernObject("_0" to range)))
        fun nodes(nodes: ModernNodes) = ModernSelectionIntent(modernObject("nodes" to modernObject("_0" to nodes)))
        fun mixed(target: ModernDeleteTarget) = ModernSelectionIntent(modernObject("mixed" to modernObject("_0" to target)))
        internal fun read(value: JSONObject) = ModernSelectionIntent(value)
    }
}
class ModernLocalSelection private constructor(value: JSONObject) : ModernValue(value) {
    companion object {
        fun capture(documentID: String, epoch: String, observed: List<ModernChangeID>, focus: ModernFocusIntent? = null, selection: ModernSelectionIntent? = null) =
            ModernLocalSelection(modernObject("documentID" to documentID, "epoch" to epoch, "observed" to JSONArray(observed.map { it.wire() }))
                .also { value -> focus?.let { value.put("focus", it.export()) }; selection?.let { value.put("selection", it.export()) } })
        fun restore(value: JSONObject) = ModernLocalSelection(value)
    }
}
enum class ModernFontFamily(val wireValue: String) { SANS("sans"), SERIF("serif"), MONOSPACE("monospace") }
enum class ModernFontSize(val wireValue: String) { SMALL("small"), DEFAULT("default"), LARGE("large") }
enum class ModernPageWidth(val wireValue: String) { READABLE("readable"), WIDE("wide") }
class ModernDocument private constructor(value: JSONObject) : ModernValue(value) {
    init { require(string("format") == "seventwo.block-editor.document" && number("formatVersion") == 1L) }
    val documentID get() = string("documentID")
    val title get() = string("title")
    val appearance get() = ModernPayload.restore(objectValue("appearance"))
    val blocks: List<ModernPayload> get() = arrayValue("blocks").let { values -> (0 until values.length()).map { ModernPayload.restore(values.getJSONObject(it)) } }
    companion object { fun restore(value: JSONObject) = ModernDocument(value) }
}
class ModernBatch private constructor(value: JSONObject) : ModernValue(value) {
    init { require(number("version") == 7L) }
    val documentID get() = string("documentID")
    val epoch get() = string("epoch")
    companion object { fun restore(value: JSONObject) = ModernBatch(value) }
}
class ModernReceipt internal constructor(value: JSONObject) : ModernValue(value) {
    val documentID get() = string("documentID")
    val epoch get() = string("epoch")
    val received: List<ModernChangeID> get() = arrayValue("received").let { values -> (0 until values.length()).map { ModernChangeID.read(values.getJSONObject(it)) } }
    companion object { fun restore(value: JSONObject) = ModernReceipt(value) }
}
class ModernRecovery internal constructor(value: JSONObject) : ModernValue(value) {
    val reason: MergeRecoveryReason get() = when (string("reason")) {
        "identityConflict" -> MergeRecoveryReason.IDENTITY_CONFLICT
        "schemaConstraint" -> MergeRecoveryReason.SCHEMA_CONSTRAINT
        else -> error("Unknown modern recovery reason")
    }
    val batch get() = ModernBatch.restore(objectValue("batch"))
    companion object { fun restore(value: JSONObject) = ModernRecovery(value) }
}
class ModernRecoveryException(val recovery: ModernRecovery) : IllegalStateException("Modern editor recovery required")
open class ModernSnapshot internal constructor(value: JSONObject) : ModernValue(value) {
    val document get() = ModernDocument.restore(objectValue("document"))
    val syncState get() = ModernReceipt(objectValue("syncState"))
    val canUndo get() = boolean("canUndo")
    val canRedo get() = boolean("canRedo")
    val recovery get() = optionalObject("recovery")?.let { ModernRecovery(it) }
}
enum class ModernResultStatus(val wireValue: String) { APPLIED("applied"), NOOP("noop"), UNAVAILABLE("unavailable"), RECOVERY_REQUIRED("recoveryRequired") }
class ModernResult internal constructor(value: JSONObject) : ModernSnapshot(value) {
    val status get() = ModernResultStatus.entries.first { it.wireValue == string("status") }
    val transaction get() = optionalObject("transaction")?.let { ModernChangeID.read(it) }
    val focusIntent get() = optionalObject("focusIntent")?.let { ModernFocusIntent.read(it) }
    val selectionIntent get() = optionalObject("selectionIntent")?.let { ModernSelectionIntent.read(it) }
    val reason get() = optionalString("reason")
    val retainedClipboard get() = optionalObject("retainedClipboard")?.let { ModernClipboard.restore(it) }
    val retainedResult get() = optionalObject("retainedResult")?.let { ModernPayload.restore(it) }
}
class ModernClipboard private constructor(value: JSONObject) : ModernValue(value) {
    val plainText get() = string("plainText")
    companion object { fun restore(value: JSONObject) = ModernClipboard(value) }
}
class ModernCutPreparation internal constructor(value: JSONObject) : ModernValue(value) {
    val preparationID get() = string("preparationID")
    val documentID get() = string("documentID")
    val epoch get() = string("epoch")
    val clipboard get() = ModernClipboard.restore(objectValue("clipboard"))
}
enum class ModernListAction(val wireValue: String) { INDENT("indent"), OUTDENT("outdent"), REORDER("reorder"), SET_STYLE("setStyle"), SET_CHECKED("setChecked") }
enum class ModernTableAction(val wireValue: String) { INSERT_ROW("insertRow"), REMOVE_ROW("removeRow"), INSERT_COLUMN("insertColumn"), REMOVE_COLUMN("removeColumn"), SET_HEADER("setHeader") }
class ModernTableTarget internal constructor(value: JSONObject) : ModernValue(value)
class ModernCodeTarget internal constructor(value: JSONObject) : ModernValue(value)
class ModernMediaTarget internal constructor(value: JSONObject) : ModernValue(value)
class ModernAvailability internal constructor(value: JSONObject) : ModernValue(value) { val available get() = boolean("available"); val reason get() = optionalString("reason") }
class ModernInsertionDescriptor internal constructor(value: JSONObject) : ModernValue(value) {
    val id get() = string("id"); val title get() = string("title"); val description get() = string("description"); val blockType get() = string("blockType"); val requiresHost get() = boolean("requiresHost")
}
enum class ModernCommandName(val wireValue: String) {
    REPLACE_TEXT("replaceText"), REPLACE_TITLE("replaceTitle"), SET_APPEARANCE("setAppearance"), FORMAT("format"), INSERT_BLOCK("insertBlock"), DUPLICATE("duplicate"), PASTE("paste"), MOVE("move"), DELETE("delete"),
    CREATE_COLUMNS("createColumns"), REMOVE_COLUMNS("removeColumns"), RESIZE_COLUMNS("resizeColumns"), CONVERT_BLOCK("convertBlock"), SOFT_BREAK("softBreak"), TYPING_SHORTCUT("typingShortcut"), SPLIT_BLOCK("splitBlock"), MERGE_BLOCKS("mergeBlocks"),
    CODE_PROPERTIES("codeProperties"), TABLE_STRUCTURE("tableStructure"), MEDIA_PROPERTIES("mediaProperties"), LIST_STRUCTURE("listStructure"), SET_SEMANTIC_COLOR("setSemanticColor"), SET_LINK("setLink"), COMPLETE_ASYNC_BLOCK("completeAsyncBlock"), UNDO("undo"), REDO("redo")
}
data class ModernPolicy(val allowedCommands: Set<ModernCommandName>? = null, val allowedListActions: Set<ModernListAction>? = null, val allowedBlockTypes: Set<String>? = null, val allowedMarkTypes: Set<String>? = null) {
    internal fun apply(value: JSONObject) {
        allowedCommands?.let { value.put("allowedCommands", JSONArray(it.map { it.wireValue }.sorted())) }
        allowedBlockTypes?.let { value.put("allowedBlockTypes", JSONArray(it.sorted())) }
        allowedMarkTypes?.let { value.put("allowedMarkTypes", JSONArray(it.sorted())) }
        allowedListActions?.let { value.put("allowedListActions", JSONArray(it.map { it.wireValue }.sorted())) }
    }
}
class ModernCapabilities internal constructor(value: JSONObject) : ModernValue(value) {
    val commands: List<ModernCommandName> get() = arrayValue("commands").let { values -> (0 until values.length()).map { index -> ModernCommandName.entries.first { it.wireValue == values.getString(index) } } }
    val canCopy get() = boolean("canCopy")
    val canCut get() = boolean("canCut")
}
class ModernAsyncTarget internal constructor(value: JSONObject) : ModernValue(value) {
    val requestID get() = string("requestID")
    val generation get() = number("generation")
    companion object { fun restore(value: JSONObject) = ModernAsyncTarget(value) }
}
class ModernAsyncRecord internal constructor(value: JSONObject) : ModernValue(value) {
    val target get() = ModernAsyncTarget(objectValue("target"))
    val status get() = string("status")
    val result get() = optionalObject("result")?.let { ModernPayload.restore(it) }
    val reason get() = optionalString("reason")
}
class ModernAsyncArchive private constructor(value: JSONObject) : ModernValue(value) {
    val requests: List<ModernAsyncRecord> get() = arrayValue("requests").let { values -> (0 until values.length()).map { ModernAsyncRecord(values.getJSONObject(it)) } }
    companion object { fun restore(value: JSONObject) = ModernAsyncArchive(value) }
}
class ModernHistorySelectionArchive private constructor(value: JSONObject) : ModernValue(value) {
    companion object { fun restore(value: JSONObject) = ModernHistorySelectionArchive(value) }
}
enum class ModernSemanticKind(val wireValue: String) { INK("ink"), FILL("fill") }
enum class ModernSemanticRole(val wireValue: String) { NEUTRAL("neutral"), GREEN("green"), BLUE("blue"), PURPLE("purple"), AMBER("amber"), RED("red") }
enum class ModernListStyle(val wireValue: String) { ORDERED("ordered"), UNORDERED("unordered"), TODO("todo") }
enum class ModernCalloutVariant(val wireValue: String) { INFO("info"), WARNING("warning"), ERROR("error"), SUCCESS("success") }
enum class ModernPasteMode(val wireValue: String) { RICH("rich"), FLATTENED_COLUMNS("flattenedColumns"), PLAIN_TEXT("plainText") }
data class ModernPastePolicy(val allowedBlockTypes: Set<String>? = null, val allowedMarkTypes: Set<String>? = null, val allowAssetMetadata: Boolean = false) {
    internal fun wire() = modernObject("allowAssetMetadata" to allowAssetMetadata).also { value ->
        allowedBlockTypes?.let { value.put("allowedBlockTypes", JSONArray(it.sorted())) }; allowedMarkTypes?.let { value.put("allowedMarkTypes", JSONArray(it.sorted())) }
    }
}
sealed class ModernPasteTarget {
    companion object {
        fun restore(value: JSONObject): ModernPasteTarget = if (value.has("range")) Range(ModernTextRange.restore(value.getJSONObject("range"))) else Boundary(ModernBoundary.restore(value.getJSONObject("boundary")), value.optJSONObject("selection")?.let { selected ->
            val ranges = selected.optJSONArray("ranges") ?: JSONArray()
            ModernDeleteTarget(selected.optJSONObject("nodes")?.let { ModernNodes.restore(it) }, (0 until ranges.length()).map { ModernTextRange.restore(ranges.getJSONObject(it)) })
        })
    }
    internal abstract fun wire(): JSONObject
    data class Range(val range: ModernTextRange) : ModernPasteTarget() { override fun wire() = modernObject("range" to range) }
    data class Boundary(val boundary: ModernBoundary, val selection: ModernDeleteTarget? = null) : ModernPasteTarget() {
        override fun wire() = modernObject("boundary" to boundary).also { value -> selection?.let { value.put("selection", it.export()) } }
    }
}
sealed class ModernSemanticTarget {
    internal abstract fun wire(): JSONObject
    data class Range(val range: ModernTextRange) : ModernSemanticTarget() { override fun wire() = modernObject("range" to range) }
    data class Nodes(val nodes: ModernNodes, val caret: ModernPosition? = null) : ModernSemanticTarget() {
        override fun wire() = modernObject("nodes" to nodes).also { value -> caret?.let { value.put("caret", it.export()) } }
    }
}
sealed class ModernCreateColumnsTarget {
    internal abstract fun wire(): JSONObject
    data class Selection(val selection: ModernNodes, val caret: ModernPosition? = null) : ModernCreateColumnsTarget() {
        override fun wire() = modernObject("selection" to selection).also { value -> caret?.let { value.put("caret", it.export()) } }
    }
    data class Boundary(val boundary: ModernBoundary, val caret: ModernPosition? = null) : ModernCreateColumnsTarget() {
        override fun wire() = modernObject("boundary" to boundary).also { value -> caret?.let { value.put("caret", it.export()) } }
    }
}
data class ModernColumnTarget(val layout: ModernNodeID, val caret: ModernPosition? = null) {
    internal fun wire() = modernObject("layout" to layout).also { value -> caret?.let { value.put("caret", it.export()) } }
}
data class ModernListTarget(val selection: ModernNodes, val caret: ModernPosition? = null, val boundary: ModernBoundary? = null) {
    internal fun wire() = modernObject("selection" to selection).also { value -> caret?.let { value.put("caret", it.export()) }; boundary?.let { value.put("boundary", it.export()) } }
}
sealed class ModernListOperation {
    internal abstract fun wire(): JSONObject
    data object Indent : ModernListOperation() { override fun wire() = modernObject("action" to "indent") }
    data object Outdent : ModernListOperation() { override fun wire() = modernObject("action" to "outdent") }
    data object Reorder : ModernListOperation() { override fun wire() = modernObject("action" to "reorder") }
    data class SetStyle(val style: ModernListStyle) : ModernListOperation() { override fun wire() = modernObject("action" to "setStyle", "style" to style.wireValue) }
    data class SetChecked(val checked: Boolean) : ModernListOperation() { override fun wire() = modernObject("action" to "setChecked", "checked" to checked) }
}
sealed class ModernBlockConversion {
    internal abstract fun wire(): JSONObject
    data object Paragraph : ModernBlockConversion() { override fun wire() = modernObject("type" to "paragraph") }
    data object Quote : ModernBlockConversion() { override fun wire() = modernObject("type" to "quote") }
    data object Code : ModernBlockConversion() { override fun wire() = modernObject("type" to "code") }
    data class Heading(val level: Int) : ModernBlockConversion() { init { require(level in 1..3) }; override fun wire() = modernObject("type" to "heading", "level" to level) }
    data class List(val style: ModernListStyle) : ModernBlockConversion() { override fun wire() = modernObject("type" to "list", "style" to style.wireValue) }
    data class Callout(val variant: ModernCalloutVariant) : ModernBlockConversion() { override fun wire() = modernObject("type" to "callout", "variant" to variant.wireValue) }
}

/** Each request couples its command, captured target and arguments. Undo/Redo have no input override. */
sealed class ModernCommand(val name: ModernCommandName) {
    internal abstract fun arguments(): JSONObject
    internal open fun target(): JSONObject? = null
    internal fun wire() = modernObject("command" to name.wireValue, "arguments" to arguments()).also { value -> target()?.let { value.put("target", it) } }
    sealed class Author(name: ModernCommandName) : ModernCommand(name)
    class ReplaceText(val range: ModernTextRange, val text: String, val typingGroup: String? = null) : Author(ModernCommandName.REPLACE_TEXT) {
        override fun target() = range.export(); override fun arguments() = textArguments(text, typingGroup)
    }
    class ReplaceTitle(val range: ModernTextRange, val text: String, val typingGroup: String? = null) : Author(ModernCommandName.REPLACE_TITLE) {
        override fun target() = range.export(); override fun arguments() = textArguments(text, typingGroup)
    }
    sealed class Appearance(val documentID: String) : Author(ModernCommandName.SET_APPEARANCE) {
        override fun target() = ModernNodeID.document(documentID).export()
        class FontFamily(documentID: String, val value: ModernFontFamily) : Appearance(documentID) { override fun arguments() = modernObject("field" to "fontFamily", "value" to value.wireValue) }
        class FontSize(documentID: String, val value: ModernFontSize) : Appearance(documentID) { override fun arguments() = modernObject("field" to "fontSize", "value" to value.wireValue) }
        class PageWidth(documentID: String, val value: ModernPageWidth) : Appearance(documentID) { override fun arguments() = modernObject("field" to "pageWidth", "value" to value.wireValue) }
    }
    class Format(val range: ModernTextRange, val markType: String, val mark: ModernPayload?) : Author(ModernCommandName.FORMAT) {
        override fun target() = range.export(); override fun arguments() = modernObject("markType" to markType, "mark" to mark)
    }
    class FormatSpan(val ranges: List<ModernTextRange>, val markType: String, val mark: ModernPayload?) : Author(ModernCommandName.FORMAT) {
        override fun target() = modernObject("ranges" to JSONArray(ranges.map { it.export() })); override fun arguments() = modernObject("markType" to markType, "mark" to mark)
    }
    class InsertBlock(val boundary: ModernBoundary, val block: ModernPayload) : Author(ModernCommandName.INSERT_BLOCK) {
        override fun target() = boundary.export(); override fun arguments() = modernObject("block" to block)
    }
    class Duplicate(val selection: ModernNodes, val boundary: ModernBoundary, val newBlockIDs: List<String>) : Author(ModernCommandName.DUPLICATE) {
        override fun target() = modernObject("selection" to selection, "boundary" to boundary); override fun arguments() = modernObject("newBlockIDs" to JSONArray(newBlockIDs))
    }
    class Paste(val destination: ModernPasteTarget, val clipboard: ModernClipboard?, val mode: ModernPasteMode = ModernPasteMode.RICH, val newIDs: List<String>? = null, val policy: ModernPastePolicy? = null, val focusInserted: Boolean = false) : Author(ModernCommandName.PASTE) {
        override fun target() = destination.wire()
        override fun arguments() = modernObject("clipboard" to clipboard, "mode" to mode.wireValue).also { value -> newIDs?.let { value.put("newIDs", JSONArray(it)) }; policy?.let { value.put("policy", it.wire()) }; if (focusInserted) value.put("focusInserted", true) }
    }
    class Move(val selection: ModernNodes, val boundary: ModernBoundary, val caret: ModernPosition? = null) : Author(ModernCommandName.MOVE) {
        override fun target() = modernObject("selection" to selection, "boundary" to boundary).also { value -> caret?.let { value.put("caret", it.export()) } }; override fun arguments() = JSONObject()
    }
    class Delete(val selection: ModernDeleteTarget) : Author(ModernCommandName.DELETE) { override fun target() = selection.export(); override fun arguments() = JSONObject() }
    class CreateColumns(val destination: ModernCreateColumnsTarget, val layout: ModernPayload) : Author(ModernCommandName.CREATE_COLUMNS) { override fun target() = destination.wire(); override fun arguments() = modernObject("layout" to layout) }
    class RemoveColumns(val column: ModernColumnTarget) : Author(ModernCommandName.REMOVE_COLUMNS) { override fun target() = column.wire(); override fun arguments() = JSONObject() }
    class ResizeColumns(val column: ModernColumnTarget, val splitBasisPoints: Int) : Author(ModernCommandName.RESIZE_COLUMNS) { override fun target() = column.wire(); override fun arguments() = modernObject("splitBasisPoints" to splitBasisPoints) }
    class ConvertBlock(val range: ModernTextRange, val conversion: ModernBlockConversion) : Author(ModernCommandName.CONVERT_BLOCK) { override fun target() = range.export(); override fun arguments() = conversion.wire() }
    class ConvertBlocks(val selection: ModernNodes, val conversion: ModernBlockConversion) : Author(ModernCommandName.CONVERT_BLOCK) { override fun target() = selection.export(); override fun arguments() = conversion.wire() }
    class TypingShortcut(val range: ModernTextRange) : Author(ModernCommandName.TYPING_SHORTCUT) { override fun target() = range.export(); override fun arguments() = JSONObject() }
    class SoftBreak(val range: ModernTextRange) : Author(ModernCommandName.SOFT_BREAK) { override fun target() = range.export(); override fun arguments() = JSONObject() }
    class SplitBlock(val range: ModernTextRange, val newBlockID: String) : Author(ModernCommandName.SPLIT_BLOCK) { override fun target() = range.export(); override fun arguments() = modernObject("newBlockID" to newBlockID) }
    class CodeProperties(val target: ModernCodeTarget, val language: String?) : Author(ModernCommandName.CODE_PROPERTIES) { override fun target() = target.export(); override fun arguments() = modernObject("language" to language) }
    class MergeBlocks(val selection: ModernNodes) : Author(ModernCommandName.MERGE_BLOCKS) { override fun target() = selection.export(); override fun arguments() = JSONObject() }
    class ListStructure(val list: ModernListTarget, val operation: ModernListOperation) : Author(ModernCommandName.LIST_STRUCTURE) { override fun target() = list.wire(); override fun arguments() = operation.wire() }
    class SetSemanticColor(val selection: ModernSemanticTarget, val kind: ModernSemanticKind, val role: ModernSemanticRole?) : Author(ModernCommandName.SET_SEMANTIC_COLOR) { override fun target() = selection.wire(); override fun arguments() = modernObject("kind" to kind.wireValue, "role" to role?.wireValue) }
    class SetLink(val range: ModernTextRange, val href: String?, val label: String? = null) : Author(ModernCommandName.SET_LINK) { override fun target() = range.export(); override fun arguments() = modernObject("href" to href).also { value -> label?.let { value.put("label", it) } } }
    class TableStructure(val table: ModernTableTarget, val action: ModernTableAction, val newIDs: List<String> = emptyList(), val header: Boolean? = null) : Author(ModernCommandName.TABLE_STRUCTURE) {
        override fun target() = table.export()
        override fun arguments() = modernObject("action" to action.wireValue, "newIDs" to JSONArray(newIDs)).also { value -> header?.let { value.put("header", it) } }
    }
    class MediaProperties(val media: ModernMediaTarget, val metadata: ModernPayload) : Author(ModernCommandName.MEDIA_PROPERTIES) {
        override fun target() = media.export(); override fun arguments() = modernObject("metadata" to metadata)
    }
    class CompleteAsyncBlock(val invocation: ModernAsyncTarget, val metadata: ModernPayload) : Author(ModernCommandName.COMPLETE_ASYNC_BLOCK) { override fun target() = invocation.export(); override fun arguments() = modernObject("metadata" to metadata) }
    data object Undo : ModernCommand(ModernCommandName.UNDO) { override fun arguments() = JSONObject() }
    data object Redo : ModernCommand(ModernCommandName.REDO) { override fun arguments() = JSONObject() }
    companion object { private fun textArguments(text: String, typingGroup: String?) = modernObject("text" to text).also { value -> typingGroup?.let { value.put("typingGroup", it) } } }
}
