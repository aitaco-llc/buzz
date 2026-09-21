import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart' as nostr;

import '../../shared/auth/auth.dart';
import '../../shared/crypto/ecdh.dart';
import '../../shared/crypto/nip44.dart';
import '../../shared/relay/relay.dart';
import '../../shared/security/sensitive_action_authorizer.dart';
import 'pairing_crypto.dart';
import 'pairing_link.dart';
import 'pairing_provider.dart';
import 'pairing_socket.dart';

/// Where "Add a device" stands. This phone is the NIP-AB _source_: it shows
/// the code, and after the six-digit check it sends this identity.
enum AddDeviceStatus {
  idle,
  preparing,
  waitingForDevice,
  confirmingSas,
  sending,
  success,
  sentUnconfirmed,
  error,
}

class AddDeviceState {
  final AddDeviceStatus status;
  final String? pairingUri;
  final String? sasCode;
  final String? errorMessage;
  final bool authorizationInProgress;

  const AddDeviceState({
    this.status = AddDeviceStatus.idle,
    this.pairingUri,
    this.sasCode,
    this.errorMessage,
    this.authorizationInProgress = false,
  });

  /// Whether a session is open and should survive the app going away.
  bool get isActive =>
      status == AddDeviceStatus.waitingForDevice ||
      status == AddDeviceStatus.confirmingSas ||
      status == AddDeviceStatus.sending;

  AddDeviceState copyWith({
    AddDeviceStatus? status,
    String? sasCode,
    String? errorMessage,
    bool? authorizationInProgress,
    bool clearErrorMessage = false,
  }) => AddDeviceState(
    status: status ?? this.status,
    pairingUri: pairingUri,
    sasCode: sasCode ?? this.sasCode,
    errorMessage: clearErrorMessage ? null : errorMessage ?? this.errorMessage,
    authorizationInProgress:
        authorizationInProgress ?? this.authorizationInProgress,
  );
}

/// NIP-AB: the whole session, from code to `complete`, is 120 s.
const addDeviceSessionTimeout = Duration(seconds: 120);

/// NIP-AB §Step 5: how long the source waits for `complete`.
const addDeviceCompleteTimeout = Duration(seconds: 30);

/// Resolves the pairing relay for [relayUrl] the way Desktop does: the
/// NIP-11 `pairing_relay_url`, else `/pair` on a NIP-43 relay, else the main
/// relay.
Future<String> resolvePairingRelayUrl(
  http.Client client,
  String relayUrl,
) async {
  final httpUri = Uri.parse(relayUrl);
  final mainWs = httpUri
      .replace(scheme: httpUri.scheme == 'http' ? 'ws' : 'wss')
      .toString();
  Map<String, dynamic>? info;
  try {
    final response = await client
        .get(
          httpUri.replace(scheme: httpUri.scheme == 'http' ? 'http' : 'https'),
          headers: const {'Accept': 'application/nostr+json'},
        )
        .timeout(const Duration(seconds: 5));
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) info = decoded;
  } catch (_) {
    return mainWs;
  }
  if (info == null) return mainWs;
  return pairingRelayUrlFromNip11(info, mainWs);
}

@visibleForTesting
String pairingRelayUrlFromNip11(Map<String, dynamic> info, String mainWs) {
  final configured = info['pairing_relay_url'];
  if (configured is String) {
    final uri = Uri.tryParse(configured);
    if (uri != null &&
        (uri.scheme == 'ws' || uri.scheme == 'wss') &&
        uri.host.isNotEmpty) {
      return configured;
    }
  }
  final nips = info['supported_nips'];
  if (nips is List && nips.contains(43)) {
    final uri = Uri.parse(mainWs);
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: '$path/pair').toString();
  }
  return mainWs;
}

class AddDeviceNotifier extends Notifier<AddDeviceState> {
  AddDeviceNotifier({PairingLinkSocketFactory? socketFactory})
    : _socketFactory = socketFactory ?? PairingSocket.new;

  final PairingLinkSocketFactory _socketFactory;

  PairingLink? _link;
  Timer? _sessionTimer;
  Timer? _completeTimer;
  int _generation = 0;

  String? _ephemeralPrivkey;
  String? _ephemeralPubkey;
  Uint8List? _sessionSecret;
  Uint8List? _sessionId;
  String? _targetPubkey;
  Uint8List? _sasInput;
  Uint8List? _conversationKey;
  Community? _community;
  final Set<String> _processedEventIds = {};

  @override
  AddDeviceState build() {
    ref.onDispose(_cleanup);
    return const AddDeviceState();
  }

  /// Opens a session and shows its code.
  Future<void> start() async {
    _cleanup();
    final generation = _generation;
    final community = ref.read(authProvider).value?.community;
    final nsec = ref.read(relayConfigProvider).nsec;
    if (community == null ||
        nsec == null ||
        nsec.isEmpty ||
        community.nsec != nsec) {
      state = const AddDeviceState(
        status: AddDeviceStatus.error,
        errorMessage: 'This phone has no aitaco identity to share.',
      );
      return;
    }
    _community = community;
    state = const AddDeviceState(status: AddDeviceStatus.preparing);

    try {
      final wsUrl = await resolvePairingRelayUrl(
        ref.read(pairingHttpClientProvider),
        community.relayUrl,
      );
      if (generation != _generation) return;

      final keys = nostr.Keys.generate();
      _ephemeralPrivkey = keys.secret;
      _ephemeralPubkey = keys.public;
      Uint8List secret;
      do {
        secret = secureRandomBytes(32);
      } while (secret.every((b) => b == 0));
      _sessionSecret = secret;
      _sessionId = deriveSessionId(secret);

      final link = PairingLink(
        socketFactory: _socketFactory,
        wsUrl: wsUrl,
        ephemeralPrivkey: keys.secret,
        subscribePubkey: keys.public,
        onEvent: (event) {
          if (generation == _generation) _handleEvent(event);
        },
        onLost: (error) {
          if (generation != _generation) return;
          _fail('Lost connection to the pairing relay.');
        },
      );
      _link = link;
      await link.connect();
      if (generation != _generation) return;

      final uri =
          'nostrpair://${keys.public}'
          '?secret=${bytesToHex(secret)}'
          '&relay=${Uri.encodeComponent(wsUrl)}'
          '&v=1';
      state = AddDeviceState(
        status: AddDeviceStatus.waitingForDevice,
        pairingUri: uri,
      );
      _sessionTimer = Timer(addDeviceSessionTimeout, () {
        if (generation != _generation || !state.isActive) return;
        _sendAbort('timeout');
        _fail('The pairing code expired. Start again.');
      });
    } catch (error) {
      if (generation != _generation) return;
      debugPrint('Add a device: $error');
      _fail(
        'Could not reach the pairing relay. Check your connection and try again.',
      );
    }
  }

  /// The user says the codes match. Asks for Face ID or the passcode, then
  /// sends `sas-confirm` and the identity.
  Future<void> confirmSas() async {
    if (state.status != AddDeviceStatus.confirmingSas ||
        state.authorizationInProgress) {
      return;
    }
    final generation = _generation;
    final community = _community!;
    state = state.copyWith(
      authorizationInProgress: true,
      clearErrorMessage: true,
    );
    final result = await ref
        .read(sensitiveActionAuthorizationSessionProvider)
        .authorize(
          biometricOnly:
              community.sensitiveActionPolicy == SensitiveActionPolicy.enabled,
        );
    if (generation != _generation ||
        state.status != AddDeviceStatus.confirmingSas) {
      return;
    }
    if (result != DeviceAuthResult.success) {
      state = state.copyWith(
        authorizationInProgress: false,
        errorMessage: _authorizationError(result),
      );
      return;
    }
    final nsec = ref.read(relayConfigProvider).nsec;
    if (nsec == null || nsec != community.nsec) {
      _sendAbort('identity_changed');
      _fail('The active identity changed. Start again.');
      return;
    }

    final transcriptHash = deriveTranscriptHash(
      _sessionId!,
      hexToBytes(_ephemeralPubkey!),
      hexToBytes(_targetPubkey!),
      _sasInput!,
      _sessionSecret!,
    );
    _publish({
      'type': 'sas-confirm',
      'transcript_hash': bytesToHex(transcriptHash),
    });
    final privkeyHex = nostr.Nip19.decode(payload: nsec).data;
    _publish({
      'type': 'payload',
      'payload_type': 'custom',
      'payload': jsonEncode({
        'relayUrl': community.relayUrl,
        'pubkey': nostr.Keys(privkeyHex).public,
        'nsec': nsec,
      }),
    });
    state = state.copyWith(
      status: AddDeviceStatus.sending,
      authorizationInProgress: false,
    );
    _sessionTimer?.cancel();
    _completeTimer = Timer(addDeviceCompleteTimeout, () {
      if (generation != _generation ||
          state.status != AddDeviceStatus.sending) {
        return;
      }
      _cleanup();
      state = const AddDeviceState(status: AddDeviceStatus.sentUnconfirmed);
    });
  }

  /// The codes differ: stop, and tell the other device why.
  void denySas() {
    if (state.status != AddDeviceStatus.confirmingSas) return;
    _sendAbort('user_denied');
    _cleanup();
    state = const AddDeviceState(
      status: AddDeviceStatus.error,
      errorMessage: 'The codes did not match. Nothing was sent.',
    );
  }

  void appBackgrounded() => _link?.appBackgrounded();

  Future<void> appResumed() async => _link?.appResumed();

  /// Leaves the page: abort an open session and forget it.
  void reset() {
    if (state.isActive && _targetPubkey != null) _sendAbort('user_denied');
    _cleanup();
    state = const AddDeviceState();
  }

  void _handleEvent(Map<String, dynamic> eventJson) {
    try {
      if (eventJson['kind'] != PairingLink.pairingKind) return;
      final eventId = eventJson['id'] as String?;
      final pubkey = eventJson['pubkey'] as String?;
      if (eventId == null || pubkey == null) return;
      if (_processedEventIds.contains(eventId)) return;
      // Once an offer is accepted, only that device may speak.
      if (_targetPubkey != null && pubkey != _targetPubkey) return;
      final tags = (eventJson['tags'] as List<dynamic>?) ?? const [];
      final taggedToUs = tags.any(
        (t) =>
            t is List &&
            t.length >= 2 &&
            t[0] == 'p' &&
            t[1] == _ephemeralPubkey,
      );
      if (!taggedToUs) return;
      final event = nostr.Event.fromJson(jsonEncode(eventJson));
      if (event.id != eventId) return;

      final content = eventJson['content'] as String?;
      if (content == null || content.isEmpty) return;
      final key = _targetPubkey == null
          ? getConversationKey(_ephemeralPrivkey!, pubkey)
          : _conversationKey!;
      final msg =
          jsonDecode(nip44Decrypt(key, content)) as Map<String, dynamic>;

      switch ((state.status, msg['type'])) {
        case (AddDeviceStatus.waitingForDevice, 'offer'):
          if (_acceptOffer(pubkey, msg)) _processedEventIds.add(eventId);
        case (AddDeviceStatus.sending, 'complete'):
          _processedEventIds.add(eventId);
          _handleComplete(msg);
        case (_, 'abort') when _targetPubkey != null && state.isActive:
          _processedEventIds.add(eventId);
          _cleanup();
          state = const AddDeviceState(
            status: AddDeviceStatus.error,
            errorMessage: 'The other device cancelled pairing.',
          );
      }
    } catch (_) {
      // NIP-AB §Event Validation: discard silently.
    }
  }

  bool _acceptOffer(String targetPubkey, Map<String, dynamic> msg) {
    if (msg['version'] != 1) {
      _fail('The other device needs a newer version of its app.');
      return true;
    }
    final sessionId = msg['session_id'];
    if (sessionId is! String || sessionId.length != 64) return false;
    if (!constantTimeEquals(hexToBytes(sessionId), _sessionId!)) return false;

    _targetPubkey = targetPubkey;
    _conversationKey = getConversationKey(_ephemeralPrivkey!, targetPubkey);
    final shared = ecdhSharedSecret(_ephemeralPrivkey!, targetPubkey);
    final (sasCode, sasInput) = deriveSas(shared, _sessionSecret!);
    _sasInput = sasInput;
    state = state.copyWith(
      status: AddDeviceStatus.confirmingSas,
      sasCode: formatSas(sasCode),
    );
    return true;
  }

  void _handleComplete(Map<String, dynamic> msg) {
    final succeeded = msg['success'] == true;
    _cleanup();
    state = succeeded
        ? const AddDeviceState(status: AddDeviceStatus.success)
        : const AddDeviceState(
            status: AddDeviceStatus.error,
            errorMessage: 'The other device could not save the identity.',
          );
  }

  void _publish(Map<String, dynamic> message) {
    final content = nip44Encrypt(_conversationKey!, jsonEncode(message));
    // Timestamp jitter (0-30 s) for metadata privacy, as the target does.
    final jitter = math.Random.secure().nextInt(31);
    final event = nostr.Event.from(
      kind: PairingLink.pairingKind,
      content: content,
      tags: [
        ['p', _targetPubkey!],
      ],
      secretKey: _ephemeralPrivkey!,
      createdAt: (DateTime.now().millisecondsSinceEpoch ~/ 1000) - jitter,
    );
    _link?.publish(event.toMap());
  }

  void _sendAbort(String reason) {
    if (_targetPubkey == null || _conversationKey == null) return;
    try {
      _publish({'type': 'abort', 'reason': reason});
    } catch (_) {
      // Best effort.
    }
  }

  void _fail(String message) {
    _cleanup();
    state = AddDeviceState(
      status: AddDeviceStatus.error,
      errorMessage: message,
    );
  }

  void _cleanup() {
    _generation++;
    _sessionTimer?.cancel();
    _sessionTimer = null;
    _completeTimer?.cancel();
    _completeTimer = null;
    _link?.dispose();
    _link = null;
    _ephemeralPrivkey = null;
    _ephemeralPubkey = null;
    _sessionSecret = null;
    _sessionId = null;
    _targetPubkey = null;
    _sasInput = null;
    _conversationKey = null;
    _community = null;
    _processedEventIds.clear();
  }

  static String _authorizationError(
    DeviceAuthResult result,
  ) => switch (result) {
    DeviceAuthResult.cancelled =>
      'Confirmation was cancelled. Nothing was sent.',
    DeviceAuthResult.unavailable =>
      'Set a device passcode or Face ID, then try again.',
    DeviceAuthResult.lockedOut =>
      'Device authentication is locked. Unlock it in Settings and try again.',
    DeviceAuthResult.failed => 'Confirmation failed. Nothing was sent.',
    DeviceAuthResult.success => '',
  };
}

final addDeviceProvider =
    NotifierProvider.autoDispose<AddDeviceNotifier, AddDeviceState>(
      AddDeviceNotifier.new,
    );
