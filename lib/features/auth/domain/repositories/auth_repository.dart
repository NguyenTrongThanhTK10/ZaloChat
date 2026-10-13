import '../entities/auth_session.dart';

abstract class AuthRepository {
  Future<AuthSession?> restore();
  Future<AuthSession> login(String email, String password);
  Future<AuthSession> register(
    String displayName,
    String email,
    String password,
  );
  Future<void> logout();
}
