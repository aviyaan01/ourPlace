import 'dart:io';
import 'package:chatbox/services/media_relay_service.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Live production implementation of [MediaRelayService] backed by Firebase Storage.
///
/// In strict accordance with zero-knowledge, ephemeral media architecture:
/// - Only client-side encrypted ciphertext blobs are transmitted to Firebase Storage.
/// - Media blobs are automatically deleted upon recipient delivery ACK (`purgeEncryptedBlob`).
/// - Files have an ephemeral TTL of 24 hours.
class FirebaseMediaRelayService implements MediaRelayService {
  final FirebaseStorage _storage;

  FirebaseMediaRelayService({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  String _cleanBlobId(String blobIdOrUrl) {
    if (blobIdOrUrl.startsWith('gs://') || blobIdOrUrl.startsWith('http://') || blobIdOrUrl.startsWith('https://')) {
      return blobIdOrUrl;
    }
    return blobIdOrUrl.replaceAll('relay://ephemeral-media/', '').replaceAll(RegExp(r'[^a-zA-Z0-9_\-\.]'), '_');
  }

  Reference _getRef(String blobIdOrUrl) {
    final clean = _cleanBlobId(blobIdOrUrl);
    if (clean.startsWith('http://') || clean.startsWith('https://') || clean.startsWith('gs://')) {
      return _storage.refFromURL(clean);
    }
    return _storage.ref('ephemeral_media').child(clean);
  }

  @override
  Future<String> uploadEncryptedBlob(
    String blobId,
    List<int> ciphertextBytes, {
    Duration ttl = const Duration(hours: 24),
  }) async {
    try {
      final ref = _getRef(blobId);
      final metadata = SettableMetadata(
        contentType: 'application/octet-stream',
        customMetadata: {
          'expiresAt': DateTime.now().toUtc().add(ttl).toIso8601String(),
          'blobId': blobId,
        },
      );

      final uploadTask = await ref.putData(
        Uint8List.fromList(ciphertextBytes),
        metadata,
      );

      final downloadUrl = await uploadTask.ref.getDownloadURL();
      return downloadUrl;
    } catch (e) {
      debugPrint('FirebaseMediaRelayService: uploadEncryptedBlob error: $e');
      rethrow;
    }
  }

  @override
  Future<Uint8List> downloadEncryptedBlob(String blobIdOrUrl) async {
    try {
      final ref = _getRef(blobIdOrUrl);
      final tempDir = await getTemporaryDirectory();
      final sanitizedName = _cleanBlobId(blobIdOrUrl).replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final tempFile = File('${tempDir.path}/nest_media_${DateTime.now().millisecondsSinceEpoch}_$sanitizedName.bin');

      final downloadTask = ref.writeToFile(tempFile);
      await downloadTask;

      if (!await tempFile.exists()) {
        throw Exception('Encrypted media blob download target file missing: $blobIdOrUrl');
      }

      final bytes = await tempFile.readAsBytes();
      try {
        await tempFile.delete();
      } catch (_) {}

      return bytes;
    } catch (e) {
      debugPrint('FirebaseMediaRelayService: downloadEncryptedBlob error: $e');
      rethrow;
    }
  }

  @override
  Future<bool> purgeEncryptedBlob(String blobIdOrUrl) async {
    try {
      final ref = _getRef(blobIdOrUrl);
      await ref.delete();
      return true;
    } catch (e) {
      debugPrint('FirebaseMediaRelayService: purgeEncryptedBlob error (may already be purged): $e');
      return false;
    }
  }

  @override
  Future<int> purgeExpiredBlobs() async {
    int purged = 0;
    try {
      final listResult = await _storage.ref('ephemeral_media').listAll();
      final now = DateTime.now().toUtc();
      for (final item in listResult.items) {
        try {
          final meta = await item.getMetadata();
          final expiresStr = meta.customMetadata?['expiresAt'];
          if (expiresStr != null) {
            final expiresAt = DateTime.tryParse(expiresStr);
            if (expiresAt != null && now.isAfter(expiresAt)) {
              await item.delete();
              purged++;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('FirebaseMediaRelayService: purgeExpiredBlobs error: $e');
    }
    return purged;
  }

  @override
  Future<bool> hasBlob(String blobIdOrUrl) async {
    try {
      final ref = _getRef(blobIdOrUrl);
      await ref.getMetadata();
      return true;
    } catch (_) {
      return false;
    }
  }
}
