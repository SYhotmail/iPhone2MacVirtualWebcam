package com.cam2mac.sender.pairing

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import java.security.KeyStore
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The Mac this phone streams to. */
class PairedMac(
    val fingerprint: ByteArray,
    val serviceName: String,
    /** Set until the Mac accepted the `pair` hello; tokens are single-use. */
    val pendingToken: ByteArray?,
)

/** This phone's identity towards the Mac, created once. */
class ClientIdentity(val clientID: UUID, val secret: ByteArray)

private val Context.pairingDataStore by preferencesDataStore(name = "pairing")

/** Persists the paired Mac and this phone's identity. The secret is wrapped with an Android Keystore AES-GCM key. */
class PairingStore(context: Context) {
    private val dataStore = context.applicationContext.pairingDataStore

    val pairedMac: Flow<PairedMac?> = dataStore.data.map { preferences ->
        val fingerprint = preferences[Keys.FINGERPRINT]?.let(Hex::decode) ?: return@map null
        val serviceName = preferences[Keys.SERVICE_NAME] ?: return@map null
        PairedMac(fingerprint, serviceName, preferences[Keys.PENDING_TOKEN]?.let(Hex::decode))
    }

    suspend fun save(invitation: PairingInvitation) {
        dataStore.edit {
            it[Keys.FINGERPRINT] = Hex.encode(invitation.fingerprint)
            it[Keys.SERVICE_NAME] = invitation.serviceName
            it[Keys.PENDING_TOKEN] = Hex.encode(invitation.token)
        }
    }

    /** The Mac accepted the `pair` hello: later connections send `hello`. */
    suspend fun markPaired() {
        dataStore.edit { it.remove(Keys.PENDING_TOKEN) }
    }

    suspend fun forgetMac() {
        dataStore.edit {
            it.remove(Keys.FINGERPRINT)
            it.remove(Keys.SERVICE_NAME)
            it.remove(Keys.PENDING_TOKEN)
        }
    }

    /** Returns this phone's identity, creating it on first use or if the Keystore key is gone. */
    suspend fun identity(): ClientIdentity {
        val preferences = dataStore.data.first()
        val existing = readIdentity(preferences)
        if (existing != null) return existing

        val identity = ClientIdentity(UUID.randomUUID(), ByteArray(SECRET_BYTES).also(SecureRandom()::nextBytes))
        val wrapped = SecretWrapper.wrap(identity.secret)
        dataStore.edit {
            it[Keys.CLIENT_ID] = identity.clientID.toString()
            it[Keys.WRAPPED_SECRET] = Base64.encodeToString(wrapped, Base64.NO_WRAP)
            // A replaced secret is unknown to the Mac, so a completed pairing can't work anymore.
            // A pending pairing still can: its `pair` hello registers the new secret.
            if (preferences[Keys.CLIENT_ID] != null && preferences[Keys.PENDING_TOKEN] == null) {
                it.remove(Keys.FINGERPRINT)
                it.remove(Keys.SERVICE_NAME)
                it.remove(Keys.PENDING_TOKEN)
            }
        }
        return identity
    }

    private fun readIdentity(preferences: Preferences): ClientIdentity? {
        val clientID = preferences[Keys.CLIENT_ID]?.let(UUID::fromString) ?: return null
        val wrapped = preferences[Keys.WRAPPED_SECRET]?.let { Base64.decode(it, Base64.NO_WRAP) } ?: return null
        val secret = SecretWrapper.unwrap(wrapped) ?: return null
        return ClientIdentity(clientID, secret)
    }

    private object Keys {
        val FINGERPRINT = stringPreferencesKey("mac_fingerprint")
        val SERVICE_NAME = stringPreferencesKey("mac_service_name")
        val PENDING_TOKEN = stringPreferencesKey("pending_token")
        val CLIENT_ID = stringPreferencesKey("client_id")
        val WRAPPED_SECRET = stringPreferencesKey("wrapped_secret")
    }

    private companion object {
        const val SECRET_BYTES = 32
    }
}

/** AES-GCM with a non-exportable Android Keystore key. Output: 12-byte IV followed by the ciphertext and tag. */
private object SecretWrapper {
    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "cam2mac-secret-wrap"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128

    fun wrap(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        return cipher.iv + cipher.doFinal(plain)
    }

    /** Returns null when the key is gone or the data was not wrapped by it. */
    fun unwrap(wrapped: ByteArray): ByteArray? = try {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, existingKey() ?: return null, GCMParameterSpec(TAG_BITS, wrapped, 0, IV_BYTES))
        cipher.doFinal(wrapped, IV_BYTES, wrapped.size - IV_BYTES)
    } catch (_: java.security.GeneralSecurityException) {
        null
    }

    private fun existingKey(): SecretKey? =
        (KeyStore.getInstance(KEYSTORE).apply { load(null) }.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey

    private fun key(): SecretKey = existingKey() ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE).run {
        init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        generateKey()
    }
}
