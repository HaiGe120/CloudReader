package io.github.haige120.cloudreader.core.ports

import java.io.Closeable

/** Clock injection keeps merge, persistence, and retry tests deterministic. */
public fun interface Clock {
    public fun nowFoundationSeconds(): Double
}

/** Credential storage is device-local and never part of a v1 manifest or export. */
public interface CredentialStore {
    public fun read(service: String, account: String): String?
    public fun write(service: String, account: String, secret: String)
    public fun delete(service: String, account: String)
}

/** Remote metadata/content boundary. Providers own authentication and transport details. */
public interface RemoteObjectStore : Closeable {
    public suspend fun read(name: String): ByteArray?
    public suspend fun write(name: String, bytes: ByteArray)
    override fun close()
}

/** HTTP and credential handling stay outside the portable assistant protocol code. */
public fun interface AITransport {
    public suspend fun send(endpoint: String, headers: Map<String, String>, body: ByteArray): ByteArray
}
