import 'dart:async';

/// Web fallback: no isolates available, so run synchronously in the event loop.
///
/// Callers should still opt into background execution for API compatibility; the
/// work simply happens on the current thread before the future completes.
Future<T> runOnIsolate<T>(T Function() computation) =>
    Future<T>.sync(computation);
