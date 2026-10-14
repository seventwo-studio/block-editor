package smoke
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import studio.seventwo.blockeditor.ModernBlockEditor
import studio.seventwo.blockeditor.ModernBlockEditorState
import studio.seventwo.blockeditor.ModernCommand
import studio.seventwo.blockeditor.ModernSession
@Composable fun Surface(state: ModernBlockEditorState, modifier: Modifier = Modifier) { ModernBlockEditor(state, modifier) }
fun Undo(session: ModernSession) = session.execute(ModernCommand.Undo)
