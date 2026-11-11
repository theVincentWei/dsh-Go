package io.github.ccch1mneyyy.dsh_app.files

/**
 * Distinct FileProvider subclass: the manifest merger forbids two <provider>
 * nodes with the same android:name, and the Dimina SDK ships its own
 * androidx.core.content.FileProvider (authority `${applicationId}.fileprovider`).
 * Subclassing keeps ours (authority `${applicationId}.files`, used by
 * files/FilesPlugin.kt and update/ApkInstaller.kt) alongside theirs unchanged —
 * authority strings, not the class, are what callers match on.
 */
class DshFileProvider : androidx.core.content.FileProvider()
