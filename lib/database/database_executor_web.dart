import 'package:drift/drift.dart';

QueryExecutor createAppQueryExecutor() {
  throw UnsupportedError(
    'Local database is disabled on web. '
    'Use RPC backend methods for all data access.',
  );
}
