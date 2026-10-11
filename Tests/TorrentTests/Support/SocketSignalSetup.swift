import Darwin

/// The fakes write over raw POSIX sockets; when a session cancels or pauses
/// while a fake is mid-write, the kernel raises SIGPIPE, which by default
/// kills the whole test process (a write to a closed socket). Ignoring SIGPIPE
/// turns that into EPIPE, which the fakes handle as a normal disconnect. Every
/// socket fake touches this in its initializer, so a test run alone is as safe
/// as one that happens to follow another (static lets are lazy).
enum SocketSignalSetup { static let installed: Void = { signal(SIGPIPE, SIG_IGN) }() }
