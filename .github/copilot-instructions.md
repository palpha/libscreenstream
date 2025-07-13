# P/Invoke & Memory Management:
- Always use strdup()/malloc() on Swift side for P/Invoke compatibility, never Swift Data with withUnsafeBytes

# Swift 6 Concurrency:
- Use @MainActor isolation for global state and UI-related APIs
- Capture raw pointer addresses as Int(bitPattern:) for @Sendable compatibility in Task closures
- Reconstruct function pointers using unsafeBitCast() inside async contexts
- Prefer @_cdecl functions with callback patterns over direct async exports for C interop

# Naming & Style Conventions:
- Match the established patterns in the codebase, but suggest improvements where applicable

# Performance & Safety:
- Prioritize P/Invoke compatibility over "modern" Swift memory management when doing C interop