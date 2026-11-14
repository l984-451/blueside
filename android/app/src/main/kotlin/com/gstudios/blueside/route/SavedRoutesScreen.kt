package com.gstudios.blueside.route

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.SavedArgs
import com.gstudios.blueside.SavedRow
import com.gstudios.blueside.id
import com.gstudios.blueside.aircraft.FullScreen
import kotlinx.coroutines.launch

// Flights and Save Flight, under the route field.
@Composable
fun SavedRoutesChips(model: AppModel, hasRoute: Boolean) {
    val route = model.route
    val labels = route.labels
    val scope = rememberCoroutineScope()
    var listOpen by remember { mutableStateOf(false) }
    var naming by remember { mutableStateOf<String?>(null) }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        AssistChip(
            onClick = { listOpen = true },
            label = { Text(labels.savedTitle) },
            leadingIcon = { Icon(Icons.Filled.Bookmarks, null, Modifier.size(AssistChipDefaults.IconSize)) },
        )
        if (hasRoute) AssistChip(
            onClick = { scope.launch { route.savedEdit(); naming = route.saved.defaultName.orEmpty() } },
            label = { Text(labels.saveRoute) },
            leadingIcon = { Icon(Icons.Filled.BookmarkAdd, null, Modifier.size(AssistChipDefaults.IconSize)) },
        )
    }
    naming?.let { start ->
        NameDialog(model, labels.saveRoute, start, onDismiss = { naming = null }) { name ->
            naming = null
            scope.launch { route.savedEdit(SavedArgs(now = 0, save = name, load = model.aircraft.flightLoad(),
                aircraft = model.aircraft.current?.id)) }
        }
    }
    if (listOpen) SavedRoutesScreen(model) { listOpen = false }
}

@Composable
private fun NameDialog(model: AppModel, title: String, start: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    val labels = model.route.labels
    var name by remember { mutableStateOf(start) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(name, { name = it }, label = { Text(labels.routeName) }, singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words))
        },
        confirmButton = { TextButton(onClick = { onSave(name) }) { Text(labels.save) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(labels.cancel) } },
    )
}

// Tap loads a route; swipe or long press removes it. Saved routes can be renamed from the long press too.
@Composable
fun SavedRoutesScreen(model: AppModel, onClose: () -> Unit) {
    val route = model.route
    val labels = route.labels
    val saved = route.saved
    val scope = rememberCoroutineScope()
    var renaming by remember { mutableStateOf<SavedRow?>(null) }
    LaunchedEffect(Unit) { route.savedEdit() }
    val load: (SavedRow) -> Unit = { row -> scope.launch { route.load(row.id, model.aircraft.fileText(), model.aircraft::restore); onClose() } }
    val remove: (SavedRow) -> Unit = { row -> scope.launch { route.savedEdit(SavedArgs(now = 0, remove = row.id)) } }
    FullScreen(title = labels.savedTitle, close = Icons.AutoMirrored.Filled.ArrowBack, onClose = onClose) {
        saved.problem?.let { item { Text(it, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error) } }
        item { Section(labels.savedSection) }
        if (saved.saved.isEmpty()) item { Text(labels.noSaved, Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        items(saved.saved, key = { "s" + it.id }) { row ->
            SavedRouteRow(model, row, load, remove, onRename = { renaming = row })
        }
        if (saved.recent.isNotEmpty()) {
            item { Section(labels.recentSection) }
            items(saved.recent, key = { "r" + it.id }) { row -> SavedRouteRow(model, row, load, remove, onRename = null) }
        }
    }
    renaming?.let { row ->
        NameDialog(model, labels.rename, row.name, onDismiss = { renaming = null }) { name ->
            renaming = null
            scope.launch { route.savedEdit(SavedArgs(now = 0, rename = row.id, name = name)) }
        }
    }
}

@Composable
private fun Section(text: String) {
    Text(text, Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
        style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SavedRouteRow(model: AppModel, row: SavedRow, onLoad: (SavedRow) -> Unit, onRemove: (SavedRow) -> Unit,
                          onRename: (() -> Unit)?) {
    val labels = model.route.labels
    val state = rememberSwipeToDismissBoxState()
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(state.currentValue) { if (state.currentValue == SwipeToDismissBoxValue.EndToStart) onRemove(row) }
    SwipeToDismissBox(
        state = state,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.errorContainer).padding(horizontal = 24.dp),
                contentAlignment = Alignment.CenterEnd) {
                Icon(Icons.Filled.Delete, labels.delete, tint = MaterialTheme.colorScheme.onErrorContainer)
            }
        },
    ) {
        Box {
            ListItem(
                supportingContent = {
                    Column {
                        Text(row.text, fontFamily = FontFamily.Monospace, maxLines = 2)
                        Text(row.detail, style = MaterialTheme.typography.bodySmall)
                    }
                },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                modifier = Modifier.fillMaxWidth().combinedClickable(onLongClick = { menu = true }) { onLoad(row) },
            ) { Text(row.name) }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                onRename?.let { rename ->
                    DropdownMenuItem(text = { Text(labels.rename) }, onClick = { menu = false; rename() })
                }
                DropdownMenuItem(text = { Text(labels.delete) }, onClick = { menu = false; onRemove(row) })
            }
        }
    }
}
