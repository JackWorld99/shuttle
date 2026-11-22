package org.localsend.localsend_app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.TileService
import android.util.Log
import androidx.annotation.RequiresApi

/**
 * Shuttle: the "Send clipboard" quick settings tile. A tap opens Shuttle with the "send clipboard" action.
 * Since Android 10 only the foreground app can read the clipboard, so the Dart side reads and sends it once the
 * app is open (HomePage._runPendingAction).
 * Modeled on [QuickTileService] in the same directory.
 */
@RequiresApi(Build.VERSION_CODES.N)
class ClipboardTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_clipboard)
        tile.label = getString(R.string.shuttle_tile_clipboard)
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = MainActivity.ACTION_SEND_CLIPBOARD
            // Include the secret token: MainActivity only accepts the action with the right token (see rememberAction)
            putExtra(MainActivity.EXTRA_TILE_TOKEN, MainActivity.tileToken(this@ClipboardTileService))
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(
                    PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                )
            } else {
                startActivityAndCollapse(intent)
            }
        } catch (e: Exception) {
            Log.w(javaClass.toString(), "Exception $e")
        }
    }
}
