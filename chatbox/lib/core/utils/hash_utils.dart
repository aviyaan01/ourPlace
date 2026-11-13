import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Cryptographic and formatting utilities for anonymous identity authentication
class HashUtils {
  static final Random _secureRandom = Random.secure();

  /// Generate a cryptographically secure random salt hex string
  static String generateSalt([int length = 16]) {
    final values = List<int>.generate(length, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Hash a candidate password with a unique per-account salt using memory/compute-hard
  /// PBKDF2-HMAC-SHA256 (10,000 iterations, 32-byte key)
  static String hashPassword(String password, String salt, {int iterations = 10000}) {
    final keyBytes = utf8.encode(password);
    final saltBytes = utf8.encode(salt);
    final hmac = Hmac(sha256, keyBytes);

    // Block 1 with index 1 (0x00000001) in big-endian
    final block1Input = Uint8List(saltBytes.length + 4);
    block1Input.setRange(0, saltBytes.length, saltBytes);
    block1Input[saltBytes.length + 3] = 1;

    var u = hmac.convert(block1Input).bytes;
    final derived = Uint8List.fromList(u);

    for (int i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (int k = 0; k < derived.length; k++) {
        derived[k] ^= u[k];
      }
    }

    return derived.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Legacy single-round SHA-256 hash for backward compatibility validation
  static String legacyHashPassword(String password, String salt) {
    final bytes = utf8.encode('$salt:$password');
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Constant-time comparison between two strings to prevent timing side-channel attacks
  static bool constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);

    if (aBytes.length != bBytes.length) {
      return false;
    }

    int result = 0;
    for (int i = 0; i < aBytes.length; i++) {
      result |= aBytes[i] ^ bBytes[i];
    }
    return result == 0;
  }

  /// Constant-time comparison between two byte lists
  static bool constantTimeBytesEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Normalize a username into standard '@username' format (lowercase, trimmed)
  static String normalizeUsername(String input) {
    final clean = input.trim().replaceAll('@', '').toLowerCase();
    return '@$clean';
  }

  /// Extract raw handle without leading '@'
  static String rawUsername(String input) {
    return input.trim().replaceAll('@', '').toLowerCase();
  }

  /// Validate username against privacy and format constraints:
  /// - 3 to 20 alphanumeric characters or underscores
  /// - No whitespace or special symbols
  static String? validateUsername(String? input) {
    if (input == null || input.trim().isEmpty) {
      return 'Username is required';
    }
    final raw = rawUsername(input);
    if (raw.length < 3) {
      return 'Username must be at least 3 characters';
    }
    if (raw.length > 20) {
      return 'Username cannot exceed 20 characters';
    }
    final validCharacters = RegExp(r'^[a-zA-Z0-9_]+$');
    if (!validCharacters.hasMatch(raw)) {
      return 'Only letters, numbers, and underscores are allowed';
    }
    return null;
  }

  /// Validate password constraints (minimum 6 characters)
  static String? validatePassword(String? input) {
    if (input == null || input.isEmpty) {
      return 'Password is required';
    }
    if (input.length < 6) {
      return 'Password must be at least 6 characters';
    }
    return null;
  }
}
