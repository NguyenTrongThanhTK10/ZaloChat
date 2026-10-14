import 'package:dio/dio.dart';

import '../../../../core/network/api_exception.dart';
import '../../../../core/security/token_store.dart';
import '../../domain/entities/auth_session.dart';
import '../../domain/entities/chat_user.dart';
import '../../domain/repositories/auth_repository.dart';

class RemoteAuthRepository implements AuthRepository {
  RemoteAuthRepository(this._dio, this._tokenStore);

  final Dio _dio;
  final TokenStore _tokenStore;

  @override
  Future<AuthSession?> restore() async {
    if (await _tokenStore.readAccessToken() == null) return null;
    final cached = await _tokenStore.readUser();
    try {
      final response = await _dio.get('/api/auth/me');
      final user = _userFromJson(response.data);
      await _saveUser(user);
      return AuthSession(user);
    } catch (error) {
      if (await _tokenStore.readRefreshToken() == null) return null;
      return cached == null ? null : AuthSession(_userFromJson(cached));
    }
  }

  @override
  Future<AuthSession> login(String email, String password) =>
      _authenticate('/api/auth/login', {'email': email, 'password': password});

  @override
  Future<AuthSession> register(
    String displayName,
    String email,
    String password,
  ) => _authenticate('/api/auth/register', {
    'displayName': displayName,
    'email': email,
    'password': password,
  });

  Future<AuthSession> _authenticate(
    String path,
    Map<String, Object> body,
  ) async {
    try {
      final response = await _dio.post(path, data: body);
      final json = Map<String, dynamic>.from(response.data as Map);
      await _tokenStore.save(
        json['accessToken'] as String,
        json['refreshToken'] as String,
      );
      final user = _userFromJson(json['user']);
      await _saveUser(user);
      return AuthSession(user);
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  @override
  Future<void> logout() => _tokenStore.clear();

  @override
  Future<ChatUser> updateProfile(String displayName, String email) async {
    try {
      final response = await _dio.put(
        '/api/auth/me',
        data: {'displayName': displayName, 'email': email},
      );
      final user = _userFromJson(response.data);
      await _saveUser(user);
      return user;
    } catch (error) {
      throw ApiException.from(error);
    }
  }

  Future<void> _saveUser(ChatUser user) => _tokenStore.saveUser({
    'id': user.id,
    'displayName': user.displayName,
    'email': user.email,
  });

  ChatUser _userFromJson(Object? source) {
    final json = Map<String, dynamic>.from(source as Map);
    return ChatUser(
      id: json['id'] as String,
      displayName: json['displayName'] as String,
      email: json['email'] as String,
    );
  }
}
