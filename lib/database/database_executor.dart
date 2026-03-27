export 'database_executor_stub.dart'
    if (dart.library.js_interop) 'database_executor_web.dart'
    if (dart.library.io) 'database_executor_native.dart';
