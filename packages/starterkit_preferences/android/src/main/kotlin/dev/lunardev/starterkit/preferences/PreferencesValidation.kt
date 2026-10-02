package dev.lunardev.starterkit.preferences

internal object PreferencesValidation {
    private val keyPattern = Regex("^[A-Za-z0-9_.-]+$")
    private val sensitiveFragments = listOf(
        "token", "access", "refresh", "password", "secret", "cookie", "auth", "apikey", "credential",
    )

    fun key(value: Any?): String? {
        if (value !is String || value.isEmpty() || value.toByteArray(Charsets.UTF_8).size > 128 ||
            !keyPattern.matches(value)
        ) return null
        val normalized = value.lowercase().replace(Regex("[^a-z0-9]"), "")
        if (sensitiveFragments.any(normalized::contains)) return null
        return value
    }

    fun value(value: Any?): String? {
        if (value !is String || value.contains('\u0000') ||
            value.toByteArray(Charsets.UTF_8).size > 4096
        ) return null
        return value
    }
}
