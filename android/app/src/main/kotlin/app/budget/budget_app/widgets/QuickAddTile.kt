package app.budget.budget_app.widgets

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.budget.budget_app.R

/** "Add expense" in the Quick Settings panel: opens the app's editor, like the quick-add widget. */
class QuickAddTile : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_INACTIVE
            label = getString(R.string.tile_add)
            updateTile()
        }
    }

    override fun onClick() {
        if (isLocked) unlockAndRun { open() } else open()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun open() {
        val intent = HomeWidgets.routeIntent(this, "add")
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 7501, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
