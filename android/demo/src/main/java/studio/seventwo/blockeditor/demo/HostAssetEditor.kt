package studio.seventwo.blockeditor.demo

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import studio.seventwo.blockeditor.BlockEditor
import studio.seventwo.blockeditor.EditorSession
import studio.seventwo.blockeditor.NodeAddress
import studio.seventwo.blockeditor.NodeIdentity
import java.util.UUID

/** This reference host explicitly obtains and retains a user-selected document grant. */
@Composable internal fun HostAssetEditor(session: EditorSession, modifier: Modifier, readOnly: Boolean,
                                        onError: (Exception) -> Unit) {
    val context = LocalContext.current
    val currentReadOnly by rememberUpdatedState(readOnly)
    val currentError by rememberUpdatedState(onError)
    var target by remember(session) { mutableStateOf<AssetTarget?>(null) }
    var picking by remember(session) { mutableStateOf(false) }
    var error by remember(session) { mutableStateOf<String?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val requested = picking
        picking = false
        val destination = target
        target = null
        if (uri != null) try {
            check(requested) { "Image selection was interrupted; select the image again" }
            check(!currentReadOnly) { "Editing is paused; select the image again after recovery" }
            require(uri.scheme == "content") { "Select an image from a document provider" }
            require(context.contentResolver.getType(uri)?.startsWith("image/") == true) { "The selected document is not an image" }
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (destination == null) {
                val blocks = session.snapshot.getJSONArray("blocks")
                session.edit("insert", JSONObject().put("after", if (blocks.length() == 0) JSONObject.NULL else blocks.getJSONObject(blocks.length() - 1).getString("id"))
                    .put("block", JSONObject().put("id", UUID.randomUUID().toString()).put("type", "image")
                        .put("src", uri.toString()).put("alt", "Selected image").put("caption", JSONArray())))
            } else if (destination.identity != null) {
                session.setNodeField(destination.identity, listOf("src"), uri.toString())
            } else {
                session.edit("setField", JSONObject().put("blockID", destination.address.blockID)
                    .put("path", JSONArray(destination.address.path + "src")).put("value", uri.toString()))
            }
            error = null
        } catch (failure: Exception) { error = failure.message; currentError(failure) }
    }
    Column(modifier) {
        error?.let { Text(it, color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
        BlockEditor(session, Modifier.weight(1f), readOnly = readOnly || picking,
            onAssetRequest = { address, _ ->
                // Resolve the origin before opening the picker; remote movement cannot redirect the edit.
                target = AssetTarget(address, if (session.syncState().optInt("version", 1) >= 2) session.node(address) else null)
                picking = true
                try { picker.launch(arrayOf("image/*")) } catch (failure: Exception) { picking = false; target = null; throw failure }
            }, onAssetInsertRequest = {
                target = null; picking = true
                try { picker.launch(arrayOf("image/*")) } catch (failure: Exception) { picking = false; throw failure }
            }, onError = onError,
            asset = { block -> LocalAsset(block) })
    }
}

private data class AssetTarget(val address: NodeAddress, val identity: NodeIdentity?)
private data class AssetPreview(val bitmap: Bitmap? = null, val error: String? = null)

/** No HTTP/file resolution: shared documents cannot cause downloads or arbitrary file reads. */
@Composable private fun LocalAsset(block: JSONObject) {
    val context = LocalContext.current
    val source = block.optString("src")
    val description = block.optString("alt", "Image").ifEmpty { "Image" }
    val preview by produceState(AssetPreview(), source) {
        value = withContext(Dispatchers.IO) {
            try {
                val uri = Uri.parse(source)
                require(uri.scheme == "content" && context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }) {
                    "Image access is unavailable on this host; select the image to grant access"
                }
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, bounds) }
                require(bounds.outWidth > 0 && bounds.outHeight > 0) { "The selected document cannot be decoded as an image" }
                var sample = 1
                while (bounds.outWidth / sample > 1600 || bounds.outHeight / sample > 1600) sample *= 2
                val options = BitmapFactory.Options().apply { inSampleSize = sample }
                val bitmap = context.contentResolver.openInputStream(uri).use { BitmapFactory.decodeStream(it, null, options) }
                AssetPreview(bitmap = checkNotNull(bitmap) { "The selected image could not be opened" })
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { AssetPreview(error = failure.message ?: "Image unavailable") }
        }
    }
    preview.bitmap?.let { Image(it.asImageBitmap(), description, Modifier.fillMaxWidth().heightIn(max = 320.dp)) }
        ?: Text(preview.error ?: "Opening image…")
}
