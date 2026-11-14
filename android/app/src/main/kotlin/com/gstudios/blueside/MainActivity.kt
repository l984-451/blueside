package com.gstudios.blueside

import android.Manifest
import android.content.pm.ApplicationInfo
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialExpressiveTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import com.gstudios.blueside.map.MapScreen
import com.gstudios.blueside.settings.SettingsScreen

class MainActivity : ComponentActivity() {
    private val model: AppModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Test hooks only in debuggable builds: a release ignores intent extras, which could wipe a store.
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        model.start(LaunchOptions.from(intent.takeIf { debuggable }))
        setContent {
            // Night forces the dark dynamic scheme.
            BluesideTheme(dark = model.night || isSystemInDarkTheme()) {
                val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
                    model.startLocation()
                }
                LaunchedEffect(Unit) {
                    ask.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                }
                // Settings opens over the map, which stays live and keeps the screen awake under it.
                // Focus leaves the map's fields, so typing never goes to a hidden panel.
                val focus = LocalFocusManager.current
                LaunchedEffect(model.settingsOpen) { if (model.settingsOpen) focus.clearFocus(force = true) }
                Box {
                    Box(if (model.settingsOpen) Modifier.clearAndSetSemantics {} else Modifier) { MapScreen(model) }
                    if (model.settingsOpen) Surface(Modifier.fillMaxSize()) { SettingsScreen(model) }
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        model.toFront()
    }

    override fun onStop() {
        super.onStop()
        model.toBack()
    }
}

// Material 3 Expressive with the system's dynamic colors (minSdk 31 always has them).
@Composable
fun BluesideTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val context = LocalContext.current
    val colors = if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    MaterialExpressiveTheme(colorScheme = colors, content = content)
}
