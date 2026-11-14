package com.gstudios.blueside.panels

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.gstudios.blueside.AppModel
import com.gstudios.blueside.Catalog

// The aeronautical switches, base maps, then overlays, in the core's order and grouping.
@Composable
fun LayerPanel(model: AppModel) {
    val plain = ListItemDefaults.colors(containerColor = Color.Transparent)
    val weather = model.weather
    val menu = model.catalog.menu
    val switches = (model.catalog.overlays + model.catalog.traffic + weather.catalog.toggles + weather.catalog.tfrs).associateBy { it.id }
    var tfrList by rememberSaveable { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxWidth()) {
        fun section(section: Catalog.Menu.Section, first: Boolean) {
            if (section.title != null) item { Header(section.title) } else if (!first) item { HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
            section.rows.forEach { row ->
                row.station?.let { id ->
                    val show = weather.catalog.shows.firstOrNull { it.id == id } ?: return@let
                    item(key = "station-$id") {
                        val on = model.overlays[weather.catalog.stationsID] == true && weather.show == id
                        ListItem(
                            trailingContent = { Checkbox(checked = on, onCheckedChange = null) },
                            colors = plain,
                            modifier = Modifier.toggleable(on, role = Role.Checkbox) {
                                weather.choose(id)
                                model.overlays[weather.catalog.stationsID] = it
                            },
                        ) { Text(show.title) }
                    }
                }
                val group = row.id?.let(switches::get) ?: return@forEach
                switches(model, listOf(group))
                if (group.id == weather.catalog.windsID && model.overlays[group.id] == true) item {
                    val levels = weather.catalog.windsLevels
                    Choose(weather.catalog.windsLevelTitle, levels.firstOrNull { it.ft == weather.windsLevel }?.title.orEmpty(),
                           levels.map { it.title }) { weather.chooseLevel(levels[it].ft) }
                }
                val tfrs = weather.tfrsWithoutArea
                if (group.id == weather.catalog.tfrsID && model.overlays[group.id] == true && tfrs.isNotEmpty()) {
                    item {
                        ListItem(
                            trailingContent = { Icon(if (tfrList) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, weather.catalog.tfrListTitle) },
                            colors = plain,
                            modifier = Modifier.clickable { tfrList = !tfrList },
                        ) { Text("${tfrs.size}${weather.catalog.tfrCountSuffix}") }
                    }
                    if (tfrList) items(tfrs) { tfr ->
                        ListItem(
                            supportingContent = { Text(listOfNotNull(tfr.detail, tfr.levels, tfr.note).joinToString("\n")) },
                            colors = plain,
                        ) { Text(tfr.title) }
                    }
                }
            }
        }
        // Plates placed on the map: a tap fits the map to one, the X takes it off.
        if (model.platesOnMap.isNotEmpty()) {
            item(key = "on-map") { Header(menu.onMap) }
            items(model.platesOnMap.toList(), key = { "on-map-${it.airport}-${it.file}" }) { plate ->
                ListItem(
                    supportingContent = { Text(plate.airport) },
                    trailingContent = { IconButton(onClick = { model.platesOnMap.remove(plate) }) { Icon(Icons.Filled.Close, "Remove ${plate.name}") } },
                    colors = plain,
                    modifier = Modifier.clickable { model.showPlate(plate) },
                ) { Text(plate.name) }
            }
            item(key = "on-map-remove-all") {
                ListItem(colors = plain, modifier = Modifier.clickable { model.platesOnMap.clear() }) {
                    Text(menu.removeAll, color = MaterialTheme.colorScheme.error)
                }
            }
            item { HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
        }
        section(menu.aeronautical, true)
        val bases = model.catalog.bases.associateBy { it.id }
        menu.bases.forEachIndexed { i, ids ->
            item { if (i == 0) Header("Base map") else HorizontalDivider(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) }
            items(ids.mapNotNull(bases::get), key = { it.id }) { base ->
                ListItem(
                    leadingContent = { RadioButton(selected = model.base == base.id, onClick = null) },
                    colors = plain,
                    modifier = Modifier.selectable(model.base == base.id, role = Role.RadioButton) { model.base = base.id },
                ) { Text(base.title) }
            }
        }
        menu.overlays.forEachIndexed { i, s -> section(s, i == 0) }
    }
}

private fun LazyListScope.switches(model: AppModel, groups: List<Catalog.Group>) {
    items(groups, key = { it.id }) { group ->
        val on = model.overlays[group.id] == true
        ListItem(
            trailingContent = { Switch(checked = on, onCheckedChange = null) },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            modifier = Modifier.toggleable(on, role = Role.Switch) { model.overlays[group.id] = it },
        ) { Text(group.title) }
    }
}

// What a station dot shows beside its flight category color.
@Composable
private fun Choose(title: String, current: String, choices: List<String>, pick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    ListItem(
        trailingContent = {
            Box {
                TextButton(onClick = { open = true }) {
                    Text(current)
                    Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
                }
                DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                    choices.forEachIndexed { i, choice ->
                        DropdownMenuItem(text = { Text(choice) }, onClick = { open = false; pick(i) })
                    }
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
    ) { Text(title) }
}

@Composable
private fun Header(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp),
    )
}
