import 'dart:async';
import 'package:chatbox/core/config/app_environment.dart';
import 'package:chatbox/core/constants/app_constants.dart';
import 'package:chatbox/core/utils/hash_utils.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

/// User identity metadata published to the public lookup directory
class DirectoryProfile {
  final String accountId;
  final String username;
  final String publicIdentityKey;
  final String? fcmToken;
  final DateTime lastSeen;

  const DirectoryProfile({
    required this.accountId,
    required this.username,
    required this.publicIdentityKey,
    this.fcmToken,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'username': username,
        'publicIdentityKey': publicIdentityKey,
        if (fcmToken != null) 'fcmToken': fcmToken,
        'lastSeen': lastSeen.toUtc().toIso8601String(),
      };

  factory DirectoryProfile.fromJson(Map<String, dynamic> json) => DirectoryProfile(
        accountId: json['accountId'] as String? ?? '',
        username: json['username'] as String? ?? '',
        publicIdentityKey: json['publicIdentityKey'] as String? ?? '',
        fcmToken: json['fcmToken'] as String?,
        lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? '') ?? DateTime.now(),
      );

  DirectoryProfile copyWith({
    String? accountId,
    String? username,
    String? publicIdentityKey,
    String? fcmToken,
    DateTime? lastSeen,
  }) {
    return DirectoryProfile(
      accountId: accountId ?? this.accountId,
      username: username ?? this.username,
      publicIdentityKey: publicIdentityKey ?? this.publicIdentityKey,
      fcmToken: fcmToken ?? this.fcmToken,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}

/// Abstract contract for central user identity & public key registry
abstract class UserDirectoryService {
  /// Publish or update user's public identity metadata
  Future<void> publishProfile(DirectoryProfile profile);

  /// Look up user's public identity and public key by normalized username
  Future<DirectoryProfile?> lookupProfile(String username);

  /// Search users across the directory by query (prefix and partial match)
  Future<List<DirectoryProfile>> searchUsers(String query);

  /// Update FCM registration token for background push delivery
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  });

  /// Update last seen heartbeat timestamp
  Future<void> updateLastSeen(String username);
}

/// In-memory mock implementation for testing and isolated offline execution
class InMemoryUserDirectoryService implements UserDirectoryService {
  final Map<String, DirectoryProfile> _directory = {};

  InMemoryUserDirectoryService([Map<String, DirectoryProfile>? initial]) {
    if (initial != null) {
      _directory.addAll(initial);
    }
  }

  @override
  Future<void> publishProfile(DirectoryProfile profile) async {
    final key = HashUtils.normalizeUsername(profile.username);
    _directory[key] = profile;
  }

  @override
  Future<DirectoryProfile?> lookupProfile(String username) async {
    final key = HashUtils.normalizeUsername(username);
    return _directory[key];
  }

  @override
  Future<List<DirectoryProfile>> searchUsers(String query) async {
    final clean = query.trim().replaceAll('@', '').toLowerCase();
    if (clean.isEmpty) return [];
    return _directory.values.where((p) {
      final u = HashUtils.rawUsername(p.username);
      return u.contains(clean) || p.accountId.contains(clean);
    }).toList();
  }

  @override
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  }) async {
    final key = HashUtils.normalizeUsername(username);
    final existing = _directory[key];
    if (existing != null) {
      _directory[key] = existing.copyWith(fcmToken: fcmToken);
    }
  }

  @override
  Future<void> updateLastSeen(String username) async {
    final key = HashUtils.normalizeUsername(username);
    final existing = _directory[key];
    if (existing != null) {
      _directory[key] = existing.copyWith(lastSeen: DateTime.now());
    }
  }
}

/// Production implementation backed by Firebase Realtime Database
class FirebaseUserDirectoryService implements UserDirectoryService {
  final FirebaseDatabase _database;
  final FirebaseAuth _auth;

  FirebaseUserDirectoryService({
    FirebaseDatabase? database,
    FirebaseAuth? auth,
  })  : _database = database ?? _defaultDatabase(),
        _auth = auth ?? _defaultAuth();

  static FirebaseDatabase _defaultDatabase() {
    try {
      return FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: AppConstants.firebaseDatabaseUrl,
      );
    } catch (_) {
      return FirebaseDatabase.instance;
    }
  }

  static FirebaseAuth _defaultAuth() {
    try {
      return FirebaseAuth.instanceFor(app: Firebase.app());
    } catch (_) {
      return FirebaseAuth.instance;
    }
  }

  Future<void> _ensureAuth() async {
    try {
      if (_auth.currentUser == null) {
        await _auth.signInAnonymously();
      }
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: _ensureAuth notice: $e');
    }
  }

  String _sanitizeKey(String username) {
    return HashUtils.normalizeUsername(username).replaceAll(RegExp(r'[^a-zA-Z0-9_@]'), '_');
  }

  DatabaseReference _dirRef(String username) {
    final key = _sanitizeKey(username);
    return _database.ref('directory').child(key);
  }

  @override
  Future<void> publishProfile(DirectoryProfile profile) async {
    try {
      await _ensureAuth();
      final currentUid = _auth.currentUser?.uid;
      // Align accountId with Firebase Auth UID to satisfy RTDB security rule:
      // newData.child('accountId').val() == auth.uid
      final effectiveProfile = (currentUid != null && currentUid.isNotEmpty && profile.accountId != currentUid)
          ? profile.copyWith(accountId: currentUid)
          : profile;

      await _dirRef(effectiveProfile.username).set(effectiveProfile.toJson());
      debugPrint('FirebaseUserDirectoryService: Successfully published profile for ${effectiveProfile.username} (UID: ${effectiveProfile.accountId})');
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: publishProfile error: $e');
      rethrow;
    }
  }

  @override
  Future<DirectoryProfile?> lookupProfile(String username) async {
    try {
      await _ensureAuth();
      final snapshot = await _dirRef(username).get();
      if (!snapshot.exists || snapshot.value == null) {
        return null;
      }
      final raw = snapshot.value;
      if (raw is Map) {
        return DirectoryProfile.fromJson(Map<String, dynamic>.from(raw));
      }
      return null;
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: lookupProfile error: $e');
      return null;
    }
  }

  @override
  Future<List<DirectoryProfile>> searchUsers(String query) async {
    final clean = query.trim().replaceAll('@', '').toLowerCase();
    if (clean.isEmpty) return [];

    try {
      await _ensureAuth();
      final results = <String, DirectoryProfile>{};

      // 1. Direct exact lookup with @
      final exactKey = '@$clean';
      final exactProfile = await lookupProfile(exactKey);
      if (exactProfile != null) {
        results[exactProfile.username] = exactProfile;
      }

      // 2. Query prefix with '@' (Firebase RTDB ordered by key)
      final prefixSnapshot = await _database
          .ref('directory')
          .orderByKey()
          .startAt(exactKey)
          .endAt('$exactKey\uf8ff')
          .limitToFirst(25)
          .get();

      if (prefixSnapshot.exists && prefixSnapshot.value is Map) {
        final rawMap = Map<dynamic, dynamic>.from(prefixSnapshot.value as Map);
        for (final entry in rawMap.entries) {
          if (entry.value is Map) {
            final profile = DirectoryProfile.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            );
            results[profile.username] = profile;
          }
        }
      }

      // 3. Fallback: Query prefix without '@' in case stored under raw handles
      if (results.isEmpty) {
        final rawSnapshot = await _database
            .ref('directory')
            .orderByKey()
            .startAt(clean)
            .endAt('$clean\uf8ff')
            .limitToFirst(25)
            .get();

        if (rawSnapshot.exists && rawSnapshot.value is Map) {
          final rawMap = Map<dynamic, dynamic>.from(rawSnapshot.value as Map);
          for (final entry in rawMap.entries) {
            if (entry.value is Map) {
              final profile = DirectoryProfile.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              );
              results[profile.username] = profile;
            }
          }
        }
      }

      return results.values.toList();
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: searchUsers error: $e');
      return [];
    }
  }

  @override
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  }) async {
    try {
      await _ensureAuth();
      await _dirRef(username).update({
        'fcmToken': fcmToken,
        'lastSeen': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: updateFcmToken error: $e');
    }
  }

  @override
  Future<void> updateLastSeen(String username) async {
    try {
      await _ensureAuth();
      await _dirRef(username).update({
        'lastSeen': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: updateLastSeen error: $e');
    }
  }
}

/// Factory that chooses between [FirebaseUserDirectoryService] in production
/// and [InMemoryUserDirectoryService] in test mode.
class DefaultUserDirectoryService implements UserDirectoryService {
  static final DefaultUserDirectoryService _instance = DefaultUserDirectoryService._internal();
  factory DefaultUserDirectoryService() => _instance;
  DefaultUserDirectoryService._internal();

  UserDirectoryService? _delegate;

  UserDirectoryService get delegate {
    if (_delegate != null) return _delegate!;
    if (AppEnvironment.isProduction) {
      _delegate = FirebaseUserDirectoryService();
    } else {
      _delegate = InMemoryUserDirectoryService();
    }
    return _delegate!;
  }

  @visibleForTesting
  void setDelegate(UserDirectoryService service) {
    _delegate = service;
  }

  @override
  Future<void> publishProfile(DirectoryProfile profile) => delegate.publishProfile(profile);

  @override
  Future<DirectoryProfile?> lookupProfile(String username) => delegate.lookupProfile(username);

  @override
  Future<List<DirectoryProfile>> searchUsers(String query) => delegate.searchUsers(query);

  @override
  Future<void> updateFcmToken({required String username, required String fcmToken}) =>
      delegate.updateFcmToken(username: username, fcmToken: fcmToken);

  @override
  Future<void> updateLastSeen(String username) => delegate.updateLastSeen(username);
}
