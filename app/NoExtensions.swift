// Compiled only when no extension directory is configured (see build.sh and test.sh): nothing extra is built.

/// An extension registers its scene here (`Extensions.registered`); without one there is nothing to register.
@MainActor func registerExtensions() {}

#if TESTING
/// An extension's own checks run here, after the panel's (`Tests.main`); and its own runs of the checks binary, by flag
/// (true: that run was one of its own, and is over).
@MainActor func extensionChecks() {}
@MainActor func extensionRun() -> Bool { false }
#endif
