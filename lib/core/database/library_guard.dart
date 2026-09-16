import 'package:sqflite/sqflite.dart';
import '../errors/app_failure.dart';

Future<void> ensureLibraryWritable(DatabaseExecutor db, String account) async {
  if ((await db.query(
    'account_metadata',
    where: 'account_id=? AND key=?',
    whereArgs: [account, 'library_operation'],
    limit: 1,
  )).isNotEmpty) {
    throw const AppFailure(FailureKind.libraryBusy);
  }
}
