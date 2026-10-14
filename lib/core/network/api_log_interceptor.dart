import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Logs request outcomes in debug builds without headers, query values, or bodies.
class ApiLogInterceptor extends Interceptor {
  final _timers = Expando<Stopwatch>();

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    _timers[options] = Stopwatch()..start();
    debugPrint('[API] --> ${options.method} ${_url(options)}');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final options = response.requestOptions;
    debugPrint(
      '[API] <-- ${response.statusCode} ${options.method} ${_url(options)}'
      '${_elapsed(options)}',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    final cause = err.error;
    final causeDescription = switch (cause) {
      SocketException(:final message) => 'SocketException: $message',
      HandshakeException(:final message) => 'HandshakeException: $message',
      null => '',
      _ => cause.runtimeType.toString(),
    };
    debugPrint(
      '[API] <-- ERROR ${options.method} ${_url(options)}'
      '${_elapsed(options)} type=${err.type.name}'
      '${err.response?.statusCode == null ? '' : ' status=${err.response!.statusCode}'}'
      '${causeDescription.isEmpty ? '' : ' cause=$causeDescription'}',
    );
    handler.next(err);
  }

  String _url(RequestOptions options) {
    final uri = options.uri;
    return '${uri.origin}${uri.path}';
  }

  String _elapsed(RequestOptions options) {
    final timer = _timers[options];
    return timer == null ? '' : ' ${timer.elapsedMilliseconds}ms';
  }
}
