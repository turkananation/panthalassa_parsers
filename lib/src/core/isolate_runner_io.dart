import 'dart:async';
import 'dart:isolate';

/// Runs [computation] on a background isolate (native platforms).
Future<T> runOnIsolate<T>(T Function() computation) => Isolate.run(computation);
