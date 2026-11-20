# Veilid's protected store (keyring-manager) talks to EncryptedSharedPreferences
# through JNI and reflective class lookups, which R8 cannot see. Without these
# keeps, release builds strip androidx.security.crypto and every device falls
# back to the unencrypted disk store ("Didn't find class
# androidx/security/crypto/MasterKey").
-keep class androidx.security.crypto.** { *; }
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**
