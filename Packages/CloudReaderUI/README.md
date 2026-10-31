# Shared application UI

These platform-neutral Compose sources are compiled directly by Android and the
Windows/Linux desktop host. Each build resolves its native Compose implementation;
the UI contains no Android, AWT, storage, credential or networking dependencies.
`CloudReaderKotlin` owns the portable values and behavior. Platform hosts supply
native reader/file/auth adapters and screen actions.
