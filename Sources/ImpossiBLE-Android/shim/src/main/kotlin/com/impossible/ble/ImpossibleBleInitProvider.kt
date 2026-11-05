package com.impossible.ble

import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri

class ImpossibleBleInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val context = context ?: return false
        val meta = context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData
        ImpossibleBle.configure(
            bundleId = context.packageName,
            token = meta?.getString(KEY_TOKEN).orEmpty(),
            host = meta?.getString(KEY_HOST) ?: ImpossibleBle.DEFAULT_HOST,
            port = meta?.getInt(KEY_PORT, ImpossibleBle.DEFAULT_PORT) ?: ImpossibleBle.DEFAULT_PORT,
        )
        return true
    }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0

    private companion object {
        const val KEY_HOST = "com.impossible.ble.HOST"
        const val KEY_PORT = "com.impossible.ble.PORT"
        const val KEY_TOKEN = "com.impossible.ble.TOKEN"
    }
}
