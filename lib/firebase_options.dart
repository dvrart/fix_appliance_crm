// Generated for Firebase project fix-appliance-cloud (not the shop).
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError('Fix Cloud web is not configured yet.');
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError('Fix Cloud iOS is not configured yet.');
      default:
        throw UnsupportedError(
          'Fix Cloud Firebase is configured for Android only so far.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAhqv-LEqgSYhLbWBWojelpZ_Brti5_YiE',
    appId: '1:749580607356:android:cec5dde745dfaccf9b4ef9',
    messagingSenderId: '749580607356',
    projectId: 'fix-appliance-cloud',
    storageBucket: 'fix-appliance-cloud.firebasestorage.app',
  );
}
