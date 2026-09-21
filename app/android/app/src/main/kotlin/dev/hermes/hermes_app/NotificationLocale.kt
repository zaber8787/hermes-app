package dev.hermes.hermes_app

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * Native mirror of the app's in-app language (I18N-PLAN §6.2). Never calls
 * Locale.setDefault or touches the Flutter lifecycle; strings are resolved
 * through a configuration context so the notification follows the APP
 * selection, not the system language.
 */
object NotificationLocale {
    private const val PREFS = "hermes_locale"
    private const val KEY = "tag"

    fun set(context: Context, tag: String): Boolean {
        if (tag != "en" && tag != "zh-Hant") return false
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, tag).apply()
        HermesStreamService.onLocaleChanged(context)
        return true
    }

    fun tag(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, "en") ?: "en"

    fun strings(context: Context): Context {
        val locale = if (tag(context) == "zh-Hant") Locale("zh", "TW") else Locale.ENGLISH
        val config = Configuration(context.resources.configuration)
        config.setLocale(locale)
        return context.createConfigurationContext(config)
    }

    fun channelName(context: Context): String =
        strings(context).getString(R.string.notification_channel_replies)

    fun activeTitle(context: Context): String =
        strings(context).getString(R.string.notification_reply_active)
}
