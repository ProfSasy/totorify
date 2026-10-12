import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the app keeps what it stores: its database, its log, the songs
/// saved for listening offline.
///
/// On a phone it is the app's Documents folder. On a computer that name is
/// the user's own "Documents", where an app's database has no business:
/// there it is the folder the system gives each app for its data.
Future<Directory> appFolder() => Platform.isWindows || Platform.isLinux
    ? getApplicationSupportDirectory()
    : getApplicationDocumentsDirectory();
