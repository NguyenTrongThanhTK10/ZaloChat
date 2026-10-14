import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static String get apiBaseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) {
      return configured.replaceFirst(RegExp(r'/+$'), '');
    }
    if (kDebugMode && defaultTargetPlatform == TargetPlatform.android) {
      //return 'http://10.0.2.2:5080';
      return 'http://192.168.1.6:45457';
    }
    return 'http://localhost:5080';
  }
}
