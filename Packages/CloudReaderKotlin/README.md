# CloudReaderKotlin

Pure Kotlin/JVM domain, v1 wire codec, deterministic merge policy, assistant
protocol helpers, and platform ports for CloudReader.

The module has no Android, Compose, Room, DataStore, reader, or provider dependencies. Platform clients provide storage and transport adapters around the portable models, `SyncCodec`/`MergePolicy`, assistant protocol helpers, and `core.ports` interfaces.

```shell
./gradlew test
```
