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
        accountId: json['accountId'] as String? ?? json['uid'] as String? ?? '',
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

  /// Search users across the directory by query (prefix match)
  Future<List<DirectoryProfile>> searchUsers(String query);

  /// Look up Firebase Auth UID directly from claimed username mapping
  Future<String?> lookupUidByUsername(String username);

  /// Update FCM registration token for background push delivery
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  });

  /// Update last seen heartbeat timestamp
  Future<void> updateLastSeen(String username);
}

/// In-memory cache entry for user prefix search results (TTL 60 seconds)
class _SearchCacheEntry {
  final List<DirectoryProfile> results;
  final DateTime timestamp;

  _SearchCacheEntry(this.results, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > const Duration(seconds: 60);
}

/// In-memory cache entry for individual user profiles (TTL 60 seconds)
class _ProfileCacheEntry {
  final DirectoryProfile profile;
  final DateTime timestamp;

  _ProfileCacheEntry(this.profile, this.timestamp);

  bool get isExpired =>
      DateTime.now().difference(timestamp) > const Duration(seconds: 60);
}

/// In-memory mock implementation for testing and isolated offline execution
class InMemoryUserDirectoryService implements UserDirectoryService {
  final Map<String, DirectoryProfile> _directory = {};
  final Map<String, String> _uidMappings = {};

  InMemoryUserDirectoryService([Map<String, DirectoryProfile>? initial]) {
    if (initial != null) {
      for (final profile in initial.values) {
        publishProfile(profile);
      }
    }
  }

  @override
  Future<void> publishProfile(DirectoryProfile profile) async {
    final normalized = HashUtils.normalizeUsername(profile.username);
    final raw = HashUtils.rawUsername(profile.username);
    _directory[normalized] = profile;
    _directory[raw] = profile;
    _uidMappings[raw] = profile.accountId;
    _uidMappings[normalized] = profile.accountId;
  }

  @override
  Future<DirectoryProfile?> lookupProfile(String username) async {
    final raw = HashUtils.rawUsername(username);
    final normalized = HashUtils.normalizeUsername(username);
    return _directory[normalized] ?? _directory[raw];
  }

  @override
  Future<List<DirectoryProfile>> searchUsers(String query) async {
    final clean = HashUtils.rawUsername(query);
    if (clean.length < 3) return [];

    final matches = <String, DirectoryProfile>{};
    for (final p in _directory.values) {
      final handle = HashUtils.rawUsername(p.username);
      if (handle.startsWith(clean)) {
        matches[handle] = p;
      }
    }
    return matches.values.take(20).toList();
  }

  @override
  Future<String?> lookupUidByUsername(String username) async {
    final raw = HashUtils.rawUsername(username);
    final normalized = HashUtils.normalizeUsername(username);
    return _uidMappings[raw] ?? _uidMappings[normalized] ?? _directory[normalized]?.accountId;
  }

  @override
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  }) async {
    final normalized = HashUtils.normalizeUsername(username);
    final raw = HashUtils.rawUsername(username);
    final existing = _directory[normalized] ?? _directory[raw];
    if (existing != null) {
      final updated = existing.copyWith(fcmToken: fcmToken);
      _directory[normalized] = updated;
      _directory[raw] = updated;
    }
  }

  @override
  Future<void> updateLastSeen(String username) async {
    final normalized = HashUtils.normalizeUsername(username);
    final raw = HashUtils.rawUsername(username);
    final existing = _directory[normalized] ?? _directory[raw];
    if (existing != null) {
      final updated = existing.copyWith(lastSeen: DateTime.now());
      _directory[normalized] = updated;
      _directory[raw] = updated;
    }
  }
}

/// Production implementation backed by Firebase Realtime Database with high-concurrency indexing
class FirebaseUserDirectoryService implements UserDirectoryService {
  final FirebaseDatabase _database;
  final FirebaseAuth _auth;

  // In-memory caching for prefix queries and profiles (TTL 60s, max 100 entries)
  final Map<String, _SearchCacheEntry> _searchCache = {};
  final Map<String, _ProfileCacheEntry> _profileCache = {};
  final Map<String, String> _uidCache = {};

  static const int _maxCacheEntries = 100;

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

  void _trimCache<K, V>(Map<K, V> cache) {
    if (cache.length > _maxCacheEntries) {
      final keysToRemove = cache.keys.take(cache.length - _maxCacheEntries).toList();
      for (final key in keysToRemove) {
        cache.remove(key);
      }
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
      final rawHandle = HashUtils.rawUsername(profile.username);
      final normalized = HashUtils.normalizeUsername(profile.username);

      final effectiveProfile = (currentUid != null && currentUid.isNotEmpty && profile.accountId != currentUid)
          ? profile.copyWith(accountId: currentUid, username: normalized)
          : profile.copyWith(username: normalized);

      // 1. Write to /users/{uid}/profile
      if (effectiveProfile.accountId.isNotEmpty) {
        await _database.ref('users').child(effectiveProfile.accountId).child('profile').set({
          'username': normalized,
          'publicIdentityKey': effectiveProfile.publicIdentityKey,
          'createdAt': ServerValue.timestamp,
        });
      }

      // 2. Write to /directory/{normalized} for backward compatibility
      await _dirRef(effectiveProfile.username).set(effectiveProfile.toJson());

      // Update in-memory caches
      _profileCache[rawHandle] = _ProfileCacheEntry(effectiveProfile, DateTime.now());
      _profileCache[normalized] = _ProfileCacheEntry(effectiveProfile, DateTime.now());
      _uidCache[rawHandle] = effectiveProfile.accountId;

      debugPrint('FirebaseUserDirectoryService: Successfully published profile for ${effectiveProfile.username} (UID: ${effectiveProfile.accountId})');
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: publishProfile error: $e');
      rethrow;
    }
  }

  @override
  Future<DirectoryProfile?> lookupProfile(String username) async {
    final raw = HashUtils.rawUsername(username);
    final normalized = HashUtils.normalizeUsername(username);
    if (raw.isEmpty) return null;

    // Check profile cache
    final cached = _profileCache[raw] ?? _profileCache[normalized];
    if (cached != null && !cached.isExpired) {
      return cached.profile;
    }

    try {
      await _ensureAuth();

      // 1. Resolve UID via /usernames/{raw}
      String? uid = await lookupUidByUsername(raw);

      if (uid != null && uid.isNotEmpty) {
        final profileSnap = await _database.ref('users').child(uid).child('profile').get();
        if (profileSnap.exists && profileSnap.value is Map) {
          final map = Map<String, dynamic>.from(profileSnap.value as Map);
          final profile = DirectoryProfile(
            accountId: uid,
            username: map['username'] as String? ?? normalized,
            publicIdentityKey: map['publicIdentityKey'] as String? ?? '',
            lastSeen: DateTime.now(),
          );
          _profileCache[raw] = _ProfileCacheEntry(profile, DateTime.now());
          _profileCache[normalized] = _ProfileCacheEntry(profile, DateTime.now());
          _trimCache(_profileCache);
          return profile;
        }
      }

      // 2. Fallback: check legacy /directory node
      final snapshot = await _dirRef(username).get();
      if (snapshot.exists && snapshot.value is Map) {
        final profile = DirectoryProfile.fromJson(
          Map<String, dynamic>.from(snapshot.value as Map),
        );
        _profileCache[raw] = _ProfileCacheEntry(profile, DateTime.now());
        _profileCache[normalized] = _ProfileCacheEntry(profile, DateTime.now());
        _trimCache(_profileCache);
        return profile;
      }

      return null;
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: lookupProfile error: $e');
      return null;
    }
  }

  @override
  Future<List<DirectoryProfile>> searchUsers(String query) async {
    final clean = HashUtils.rawUsername(query);
    // Requirement 2: Require minimum 3 characters before querying Firebase
    if (clean.length < 3) return [];

    final stopwatch = Stopwatch()..start();

    // Requirement 5: In-memory cache for prefix results (TTL 60s, max 100 entries)
    final cached = _searchCache[clean];
    if (cached != null && !cached.isExpired) {
      if (AppConstants.enableDebugLogs) {
        debugPrint(
          'SEARCH: prefix=$clean, count=${cached.results.length}, latency=${stopwatch.elapsedMilliseconds}ms (cached)',
        );
      }
      return cached.results;
    }

    try {
      await _ensureAuth();
      final results = <String, DirectoryProfile>{};

      // Requirement 1: Prefix search on /usernames using:
      // startAt(clean).endAt(clean + '\uf8ff').limitToFirst(20)
      final usernamesSnapshot = await _database
          .ref('usernames')
          .orderByKey()
          .startAt(clean)
          .endAt('$clean\uf8ff')
          .limitToFirst(20)
          .get();

      if (usernamesSnapshot.exists && usernamesSnapshot.value is Map) {
        final rawMap = Map<dynamic, dynamic>.from(usernamesSnapshot.value as Map);
        final profileLookups = <Future<DirectoryProfile?>>[];

        for (final entry in rawMap.entries) {
          final handle = entry.key.toString();
          final uid = entry.value.toString();
          _uidCache[handle] = uid;

          // Check if profile is already cached
          final cachedProfile = _profileCache[handle];
          if (cachedProfile != null && !cachedProfile.isExpired) {
            results[handle] = cachedProfile.profile;
          } else {
            profileLookups.add(
              _database.ref('users').child(uid).child('profile').get().then((snap) {
                if (snap.exists && snap.value is Map) {
                  final map = Map<String, dynamic>.from(snap.value as Map);
                  final prof = DirectoryProfile(
                    accountId: uid,
                    username: map['username'] as String? ?? '@$handle',
                    publicIdentityKey: map['publicIdentityKey'] as String? ?? '',
                    lastSeen: DateTime.now(),
                  );
                  _profileCache[handle] = _ProfileCacheEntry(prof, DateTime.now());
                  return prof;
                }
                return null;
              }).catchError((_) => null),
            );
          }
        }

        if (profileLookups.isNotEmpty) {
          final fetched = await Future.wait(profileLookups);
          for (final prof in fetched) {
            if (prof != null) {
              results[HashUtils.rawUsername(prof.username)] = prof;
            }
          }
        }
      }

      // Fallback: If /usernames returned 0 results, check /directory for backward compatibility
      if (results.isEmpty) {
        final exactKey = '@$clean';
        final prefixSnapshot = await _database
            .ref('directory')
            .orderByKey()
            .startAt(exactKey)
            .endAt('$exactKey\uf8ff')
            .limitToFirst(20)
            .get();

        if (prefixSnapshot.exists && prefixSnapshot.value is Map) {
          final rawMap = Map<dynamic, dynamic>.from(prefixSnapshot.value as Map);
          for (final entry in rawMap.entries) {
            if (entry.value is Map) {
              final profile = DirectoryProfile.fromJson(
                Map<String, dynamic>.from(entry.value as Map),
              );
              results[HashUtils.rawUsername(profile.username)] = profile;
            }
          }
        }
      }

      final resultList = results.values.take(20).toList();

      // Cache the result
      _searchCache[clean] = _SearchCacheEntry(resultList, DateTime.now());
      _trimCache(_searchCache);
      _trimCache(_profileCache);

      stopwatch.stop();
      if (AppConstants.enableDebugLogs) {
        debugPrint(
          'SEARCH: prefix=$clean, count=${resultList.length}, latency=${stopwatch.elapsedMilliseconds}ms',
        );
      }

      return resultList;
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: searchUsers error: $e');
      rethrow;
    }
  }

  @override
  Future<String?> lookupUidByUsername(String username) async {
    final clean = HashUtils.rawUsername(username);
    if (clean.isEmpty) return null;

    final cached = _uidCache[clean];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    try {
      await _ensureAuth();
      final snap = await _database.ref('usernames').child(clean).get();
      if (snap.exists && snap.value != null) {
        final uid = snap.value.toString();
        _uidCache[clean] = uid;
        return uid;
      }

      // Fallback: check /directory/@clean
      final dirSnap = await _dirRef(username).get();
      if (dirSnap.exists && dirSnap.value is Map) {
        final map = Map<String, dynamic>.from(dirSnap.value as Map);
        final uid = map['accountId'] as String?;
        if (uid != null && uid.isNotEmpty) {
          _uidCache[clean] = uid;
          return uid;
        }
      }
    } catch (e) {
      debugPrint('FirebaseUserDirectoryService: lookupUidByUsername error: $e');
    }
    return null;
  }

  @override
  Future<void> updateFcmToken({
    required String username,
    required String fcmToken,
  }) async {
    try {
      await _ensureAuth();
      final uid = await lookupUidByUsername(username) ?? _auth.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) {
        await _database.ref('users').child(uid).child('private').child('fcm').set(fcmToken);
      }
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
      final uid = await lookupUidByUsername(username) ?? _auth.currentUser?.uid;
      if (uid != null && uid.isNotEmpty) {
        await _database.ref('presence').child(uid).update({
          'online': true,
          'lastSeen': ServerValue.timestamp,
        });
      }
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
  Future<String?> lookupUidByUsername(String username) => delegate.lookupUidByUsername(username);

  @override
  Future<void> updateFcmToken({required String username, required String fcmToken}) =>
      delegate.updateFcmToken(username: username, fcmToken: fcmToken);

  @override
  Future<void> updateLastSeen(String username) => delegate.updateLastSeen(username);
}
