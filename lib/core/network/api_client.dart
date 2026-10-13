import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../security/token_store.dart';

class ApiClient {
  ApiClient(this._tokenStore)
    : dio = Dio(
        BaseOptions(
          baseUrl: AppConfig.apiBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
          headers: {'Accept': 'application/json'},
        ),
      ) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await _tokenStore.readAccessToken();
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
        onError: (error, handler) async {
          final options = error.requestOptions;
          if (error.response?.statusCode != 401 ||
              options.extra['retried'] == true ||
              const {
                '/api/auth/login',
                '/api/auth/register',
                '/api/auth/refresh',
              }.contains(options.path)) {
            handler.next(error);
            return;
          }

          try {
            final token = await _refreshAccessToken();
            if (token == null) {
              handler.next(error);
              return;
            }
            options.extra['retried'] = true;
            options.headers['Authorization'] = 'Bearer $token';
            handler.resolve(await dio.fetch<dynamic>(options));
          } catch (_) {
            handler.next(error);
          }
        },
      ),
    );
  }

  final TokenStore _tokenStore;
  final Dio dio;
  final _sessionExpired = StreamController<void>.broadcast();
  Future<String?>? _refreshing;

  Stream<void> get sessionExpired => _sessionExpired.stream;

  void dispose() {
    dio.close(force: true);
    _sessionExpired.close();
  }

  Future<String?> _refreshAccessToken() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await _tokenStore.readRefreshToken();
    if (refreshToken == null) {
      await _expireSession();
      return null;
    }
    try {
      final response = await Dio(BaseOptions(baseUrl: AppConfig.apiBaseUrl))
          .post('/api/auth/refresh', data: {'refreshToken': refreshToken});
      final body = Map<String, dynamic>.from(response.data as Map);
      final access = body['accessToken'] as String;
      final refresh = body['refreshToken'] as String;
      await _tokenStore.save(access, refresh);
      return access;
    } on DioException catch (error) {
      if (error.response?.statusCode == 400 ||
          error.response?.statusCode == 401) {
        await _expireSession();
      }
      return null;
    }
  }

  Future<void> _expireSession() async {
    await _tokenStore.clear();
    if (!_sessionExpired.isClosed) _sessionExpired.add(null);
  }
}
