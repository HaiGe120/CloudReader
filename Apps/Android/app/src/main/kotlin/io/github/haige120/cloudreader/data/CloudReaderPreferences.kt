package io.github.haige120.cloudreader.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.settingsDataStore by preferencesDataStore(name = "cloudreader_settings")

class CloudReaderPreferences(private val context: Context) {
    private val selectedKey = stringSetPreferencesKey("sync_destinations")
    val selectedProviders: Flow<Set<String>> = context.settingsDataStore.data.map { it[selectedKey] ?: emptySet() }

    suspend fun selectProvider(name: String, selected: Boolean) {
        context.settingsDataStore.edit { values ->
            val updated = (values[selectedKey] ?: emptySet()).toMutableSet()
            if (selected) updated.add(name) else updated.remove(name)
            values[selectedKey] = updated
        }
    }

    suspend fun get(key: String): String? = context.settingsDataStore.data.first()[stringPreferencesKey(key)]

    fun observe(key: String, default: String): Flow<String> = context.settingsDataStore.data.map {
        it[stringPreferencesKey(key)] ?: default
    }

    suspend fun set(key: String, value: String?) {
        val preference = stringPreferencesKey(key)
        context.settingsDataStore.edit { values -> if (value == null) values.remove(preference) else values[preference] = value }
    }

    suspend fun getBool(key: String, default: Boolean = false): Boolean = get(key)?.toBooleanStrictOrNull() ?: default
    suspend fun setBool(key: String, value: Boolean) = set(key, value.toString())
}

/** AES/GCM secrets encrypted with a non-exportable key in Android Keystore. */
class SecureVault(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("cloudreader_vault", Context.MODE_PRIVATE)
    private val keyAlias = "io.github.haige120.cloudreader.vault.v1"

    fun put(name: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val cipherText = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val record = cipher.iv + cipherText
        check(preferences.edit().putString(name, Base64.encodeToString(record, Base64.NO_WRAP)).commit()) { "Could not save secure setting" }
    }

    fun get(name: String): String? = runCatching {
        val record = Base64.decode(preferences.getString(name, null), Base64.NO_WRAP)
        require(record.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), javax.crypto.spec.GCMParameterSpec(128, record.copyOfRange(0, 12)))
        cipher.doFinal(record.copyOfRange(12, record.size)).toString(Charsets.UTF_8)
    }.getOrNull()

    fun remove(name: String) { preferences.edit().remove(name).apply() }

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(keyAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true).build())
        return generator.generateKey()
    }
}
