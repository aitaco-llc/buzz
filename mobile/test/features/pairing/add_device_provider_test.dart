import 'dart:async';
import 'dart:convert';

import 'package:buzz/features/pairing/add_device_provider.dart';
import 'package:buzz/features/pairing/pairing_link.dart';
import 'package:buzz/features/pairing/pairing_provider.dart';
import 'package:buzz/features/pairing/pairing_socket.dart';
import 'package:buzz/shared/auth/auth.dart';
import 'package:buzz/shared/crypto/nip44.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/security/sensitive_action_authorizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_auth/local_auth.dart';
import 'package:nostr/nostr.dart' as nostr;

/// "Add a device": this phone as the NIP-AB source, paired against our own
/// target over an in-memory pair relay that holds undelivered events the way
/// buzz-pair-relay does (aitaco-llc/buzz#28).
void main() {
  group('pairingRelayUrlFromNip11', () {
    const main = 'wss://buzz.aitaco.co';

    test('prefers the advertised pairing relay', () {
      expect(
        pairingRelayUrlFromNip11({
          'pairing_relay_url': 'wss://pair.example',
          'supported_nips': [43],
        }, main),
        'wss://pair.example',
      );
    });

    test('uses /pair on a NIP-43 relay', () {
      expect(
        pairingRelayUrlFromNip11({
          'supported_nips': [1, 42, 43],
        }, main),
        'wss://buzz.aitaco.co/pair',
      );
    });

    test('falls back to the main relay', () {
      expect(
        pairingRelayUrlFromNip11({
          'supported_nips': [1],
          'pairing_relay_url': 'https://not-a-socket',
        }, main),
        main,
      );
    });
  });

  group('AddDeviceNotifier', () {
    late _PairRelay relay;
    late _Phone source;
    late _TargetApp target;

    setUp(() async {
      relay = _PairRelay();
      source = _Phone(relay);
      target = _TargetApp(relay);
      await source.container.read(authProvider.future);
    });

    tearDown(() {
      source.container.dispose();
      target.container.dispose();
    });

    test('shows a nostrpair code on the pairing relay', () async {
      await source.notifier.start();
      final state = source.state;
      expect(state.status, AddDeviceStatus.waitingForDevice);
      final uri = Uri.parse(state.pairingUri!);
      expect(uri.scheme, 'nostrpair');
      expect(uri.queryParameters['relay'], 'wss://buzz.aitaco.co/pair');
      expect(uri.queryParameters['v'], '1');
      expect(relay.connectedUrls, ['wss://buzz.aitaco.co/pair']);
    });

    test(
      'pairs two apps on one phone, each in the background in turn',
      () async {
        await source.notifier.start();
        final code = source.state.pairingUri!;

        // Copy the code, switch to the other app: the source is suspended.
        source.notifier.appBackgrounded();
        relay.suspend(source.subscriptionKey!);

        await target.notifier.pair(code);
        final targetSas = target.state.sasCode;
        expect(target.state.status, PairingStatus.confirmingSas);
        target.notifier.confirmSas();

        // Back to the source: the held offer arrives on the new REQ.
        target.notifier.appBackgrounded();
        relay.suspend(target.subscriptionKey!);
        await source.notifier.appResumed();
        await pumpEventQueue();
        expect(source.state.status, AddDeviceStatus.confirmingSas);
        expect(source.state.sasCode, targetSas);

        await source.notifier.confirmSas();
        expect(source.authorizer.calls, 1);
        expect(source.state.status, AddDeviceStatus.sending);

        // Back to the target: sas-confirm and payload were held for it.
        source.notifier.appBackgrounded();
        relay.suspend(source.subscriptionKey!);
        await target.notifier.appResumed();
        await pumpEventQueue();
        expect(target.state.status, PairingStatus.success);
        expect(target.auth.lastCommunity?.nsec, _SourceConfig.nsec);
        expect(target.auth.lastCommunity?.pubkey, _SourceConfig.pubkey);
        expect(target.auth.lastCommunity?.relayUrl, 'https://buzz.aitaco.co');

        // And the source hears `complete` when it comes back.
        await source.notifier.appResumed();
        await pumpEventQueue();
        expect(source.state.status, AddDeviceStatus.success);
      },
    );

    test('cancelled Face ID sends nothing and can be retried', () async {
      await source.notifier.start();
      await target.notifier.pair(source.state.pairingUri!);
      await pumpEventQueue();
      expect(source.state.status, AddDeviceStatus.confirmingSas);

      source.authorizer.result = DeviceAuthResult.cancelled;
      final before = relay.published.length;
      await source.notifier.confirmSas();
      expect(source.state.status, AddDeviceStatus.confirmingSas);
      expect(source.state.errorMessage, contains('Nothing was sent'));
      expect(relay.published.length, before);

      source.authorizer.result = DeviceAuthResult.success;
      await source.notifier.confirmSas();
      expect(source.state.status, AddDeviceStatus.sending);
    });

    test('denying the code aborts the other device', () async {
      await source.notifier.start();
      await target.notifier.pair(source.state.pairingUri!);
      await pumpEventQueue();

      source.notifier.denySas();
      await pumpEventQueue();
      expect(source.state.status, AddDeviceStatus.error);
      expect(target.state.status, PairingStatus.error);
      expect(target.state.errorMessage, contains('user_denied'));
      expect(
        relay.decryptedTypesFrom(source.lastEphemeralSecret!),
        isNot(contains('payload')),
      );
    });

    test('ignores an offer with the wrong session id', () async {
      await source.notifier.start();
      final uri = Uri.parse(source.state.pairingUri!);
      final forged = uri
          .replace(
            queryParameters: {...uri.queryParameters, 'secret': 'ab' * 32},
          )
          .toString();
      await target.notifier.pair(forged);
      await pumpEventQueue();
      expect(source.state.status, AddDeviceStatus.waitingForDevice);
    });

    test('refuses to start without an identity', () async {
      final phone = _Phone(relay, signedIn: false);
      await phone.container.read(authProvider.future);
      addTearDown(phone.container.dispose);
      await phone.notifier.start();
      expect(phone.state.status, AddDeviceStatus.error);
      expect(relay.connectedUrls, isEmpty);
    });
  });

  group('PairingLink', () {
    test('re-sends an event the relay never acknowledged', () async {
      final relay = _PairRelay();
      final receiver = nostr.Keys.generate();
      final received = <String>[];
      final listener = PairingLink(
        socketFactory: relay.factory,
        wsUrl: 'wss://pair',
        ephemeralPrivkey: receiver.secret,
        subscribePubkey: receiver.public,
        onEvent: (e) => received.add(e['id'] as String),
        onLost: (_) => fail('listener lost'),
      );
      await listener.connect();

      final sender = nostr.Keys.generate();
      final link = PairingLink(
        socketFactory: relay.factory,
        wsUrl: 'wss://pair',
        ephemeralPrivkey: sender.secret,
        subscribePubkey: sender.public,
        onEvent: (_) {},
        onLost: (_) => fail('sender lost'),
      );
      await link.connect();

      // The write lands in a socket iOS already suspended.
      relay.suspend(sender.public, notify: false);
      final event = nostr.Event.from(
        kind: 24134,
        content: 'x',
        tags: [
          ['p', receiver.public],
        ],
        secretKey: sender.secret,
      ).toMap();
      link.publish(event);
      await pumpEventQueue();
      expect(received, isEmpty);

      link.appBackgrounded();
      await link.appResumed();
      await pumpEventQueue();
      expect(received, [event['id']]);
    });

    test('a drop in the background waits for resume', () async {
      final relay = _PairRelay();
      final keys = nostr.Keys.generate();
      var lost = 0;
      final link = PairingLink(
        socketFactory: relay.factory,
        wsUrl: 'wss://pair',
        ephemeralPrivkey: keys.secret,
        subscribePubkey: keys.public,
        onEvent: (_) {},
        onLost: (_) => lost++,
      );
      await link.connect();
      link.appBackgrounded();
      relay.suspend(keys.public);
      await pumpEventQueue();
      expect(lost, 0);
      expect(relay.connections, 1);

      await link.appResumed();
      expect(relay.connections, 2);
      expect(link.isConnected, isTrue);
    });

    test('a drop in the foreground reconnects once', () async {
      final relay = _PairRelay();
      final keys = nostr.Keys.generate();
      var lost = 0;
      final link = PairingLink(
        socketFactory: relay.factory,
        wsUrl: 'wss://pair',
        ephemeralPrivkey: keys.secret,
        subscribePubkey: keys.public,
        onEvent: (_) {},
        onLost: (_) => lost++,
      );
      await link.connect();
      relay.suspend(keys.public);
      await pumpEventQueue();
      expect(relay.connections, 2);
      expect(lost, 0);

      relay.refuseConnections = true;
      relay.suspend(keys.public);
      await pumpEventQueue();
      expect(lost, 1);
    });
  });
}

/// The phone running "Add a device".
class _Phone {
  _Phone(this.relay, {bool signedIn = true}) : authorizer = _Authorizer() {
    final nsec = signedIn ? _SourceConfig.nsec : null;
    final community = nsec == null
        ? null
        : Community(
            id: 'aitaco',
            name: 'aitaco',
            relayUrl: 'https://buzz.aitaco.co',
            nsec: nsec,
            sensitiveActionPolicy: SensitiveActionPolicy.disabledByUser,
            addedAt: DateTime.utc(2026),
          );
    container = ProviderContainer(
      overrides: [
        addDeviceProvider.overrideWith(
          () => AddDeviceNotifier(socketFactory: _recordingFactory),
        ),
        authProvider.overrideWith(() => _SignedInAuth(community)),
        relayConfigProvider.overrideWith(() => _SourceConfig(nsec)),
        sensitiveActionAuthorizerProvider.overrideWithValue(authorizer),
        pairingHttpClientProvider.overrideWithValue(_nip11Client),
      ],
    );
    container.listen(addDeviceProvider, (_, _) {});
  }

  final _PairRelay relay;
  final _Authorizer authorizer;
  late final ProviderContainer container;
  String? lastEphemeralSecret;

  AddDeviceNotifier get notifier => container.read(addDeviceProvider.notifier);
  AddDeviceState get state => container.read(addDeviceProvider);

  String? get subscriptionKey => lastEphemeralSecret == null
      ? null
      : nostr.Keys(lastEphemeralSecret!).public;

  PairingSocket _recordingFactory({
    required String wsUrl,
    required String ephemeralPrivkey,
    required void Function(List<dynamic> message) onMessage,
    required void Function(Object? error) onDisconnected,
  }) {
    lastEphemeralSecret = ephemeralPrivkey;
    return relay.factory(
      wsUrl: wsUrl,
      ephemeralPrivkey: ephemeralPrivkey,
      onMessage: onMessage,
      onDisconnected: onDisconnected,
    );
  }
}

/// Our own app as the target (welcome screen / "Sign in from another device").
class _TargetApp {
  _TargetApp(this.relay) : auth = _RecordingAuth() {
    container = ProviderContainer(
      overrides: [
        pairingProvider.overrideWith(
          () => PairingNotifier(
            socketFactory: _recordingFactory,
            credentialValidator: ({required relayUrl, required nsec}) async {},
          ),
        ),
        authProvider.overrideWith(() => auth),
        relayConfigProvider.overrideWith(() => _SourceConfig(null)),
        sensitiveActionAuthorizerProvider.overrideWithValue(_Authorizer()),
      ],
    );
  }

  final _PairRelay relay;
  final _RecordingAuth auth;
  late final ProviderContainer container;
  String? _secret;

  PairingNotifier get notifier => container.read(pairingProvider.notifier);
  PairingState get state => container.read(pairingProvider);
  String? get subscriptionKey =>
      _secret == null ? null : nostr.Keys(_secret!).public;

  PairingSocket _recordingFactory({
    required String wsUrl,
    required String ephemeralPrivkey,
    required void Function(List<dynamic> message) onMessage,
    required void Function(Object? error) onDisconnected,
  }) {
    _secret = ephemeralPrivkey;
    return relay.factory(
      wsUrl: wsUrl,
      ephemeralPrivkey: ephemeralPrivkey,
      onMessage: onMessage,
      onDisconnected: onDisconnected,
    );
  }
}

final _nip11Client = MockClient(
  (request) async => http.Response(
    jsonEncode({
      'supported_nips': [1, 42, 43],
    }),
    200,
  ),
);

/// Routes kind:24134 by `#p` and holds what it cannot deliver, as
/// buzz-pair-relay does. A new REQ for a `#p` replaces the old one and gets
/// what was held.
class _PairRelay {
  final Map<String, _RelaySocket> _subscribers = {};
  final Map<String, List<Map<String, dynamic>>> _held = {};
  final List<Map<String, dynamic>> published = [];
  final List<String> connectedUrls = [];
  int connections = 0;
  bool refuseConnections = false;

  PairingSocket factory({
    required String wsUrl,
    required String ephemeralPrivkey,
    required void Function(List<dynamic> message) onMessage,
    required void Function(Object? error) onDisconnected,
  }) => _RelaySocket(this, wsUrl, ephemeralPrivkey, onMessage, onDisconnected);

  /// iOS suspends the app that owns the subscription for [pubkey].
  void suspend(String pubkey, {bool notify = true}) {
    final socket = _subscribers[pubkey];
    if (socket == null) return;
    socket.alive = false;
    _subscribers.remove(pubkey);
    if (notify) {
      scheduleMicrotask(
        () => socket.disconnected(Exception('socket suspended')),
      );
    }
  }

  List<String> decryptedTypesFrom(String senderSecret) {
    final sender = nostr.Keys(senderSecret).public;
    return [
      for (final event in published)
        if (event['pubkey'] == sender)
          (jsonDecode(
                    nip44Decrypt(
                      getConversationKey(
                        senderSecret,
                        (event['tags'] as List).first[1] as String,
                      ),
                      event['content'] as String,
                    ),
                  )
                  as Map<String, dynamic>)['type']
              as String,
    ];
  }

  void _subscribe(String pubkey, _RelaySocket socket) {
    _subscribers[pubkey] = socket;
    final held = _held.remove(pubkey) ?? const [];
    for (final event in held) {
      _deliver(socket, event);
    }
  }

  void _publish(_RelaySocket from, Map<String, dynamic> event) {
    if (!from.alive) return; // Lost in a suspended socket: no OK.
    published.add(event);
    scheduleMicrotask(() => from.message(['OK', event['id'], true, '']));
    final p = ((event['tags'] as List).first as List)[1] as String;
    final socket = _subscribers[p];
    if (socket == null || !socket.alive) {
      (_held[p] ??= []).add(event);
    } else {
      _deliver(socket, event);
    }
  }

  void _deliver(_RelaySocket socket, Map<String, dynamic> event) {
    scheduleMicrotask(() {
      if (socket.alive) socket.message(['EVENT', 'pair', event]);
    });
  }
}

class _RelaySocket extends PairingSocket {
  _RelaySocket(
    this.relay,
    String wsUrl,
    String ephemeralPrivkey,
    this.message,
    this.disconnected,
  ) : _wsUrl = wsUrl,
      super(
        wsUrl: wsUrl,
        ephemeralPrivkey: ephemeralPrivkey,
        onMessage: message,
        onDisconnected: disconnected,
      );

  final _PairRelay relay;
  final String _wsUrl;
  final void Function(List<dynamic> message) message;
  final void Function(Object? error) disconnected;
  bool alive = false;

  @override
  bool get isConnected => alive;

  @override
  Future<void> connect() async {
    if (relay.refuseConnections) {
      disconnected(Exception('refused'));
      throw Exception('refused');
    }
    relay.connections++;
    relay.connectedUrls.add(_wsUrl);
    alive = true;
  }

  @override
  void subscribe(String subId, int kind, String pubkeyHex) =>
      relay._subscribe(pubkeyHex, this);

  @override
  void publishEvent(Map<String, dynamic> event) => relay._publish(this, event);

  @override
  void dispose() => alive = false;
}

class _SourceConfig extends RelayConfigNotifier {
  _SourceConfig(this._nsec);

  static final nsec = nostr.Keys(
    '2222222222222222222222222222222222222222222222222222222222222222',
  ).nsec;
  static final pubkey = nostr.Keys(
    '2222222222222222222222222222222222222222222222222222222222222222',
  ).public;

  final String? _nsec;

  @override
  RelayConfig build() =>
      RelayConfig(baseUrl: 'https://buzz.aitaco.co', nsec: _nsec);
}

class _SignedInAuth extends AsyncNotifier<AuthState> implements AuthNotifier {
  _SignedInAuth(this._community);

  final Community? _community;

  @override
  Future<AuthState> build() async => _community == null
      ? const AuthState(status: AuthStatus.unauthenticated)
      : AuthState(status: AuthStatus.authenticated, community: _community);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingAuth extends AsyncNotifier<AuthState> implements AuthNotifier {
  Community? lastCommunity;

  @override
  Future<AuthState> build() async =>
      const AuthState(status: AuthStatus.unauthenticated);

  @override
  Future<void> authenticateWithCommunity(Community community) async {
    lastCommunity = community;
    state = AsyncData(
      AuthState(status: AuthStatus.authenticated, community: community),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Authorizer implements SensitiveActionAuthorizer {
  DeviceAuthResult result = DeviceAuthResult.success;
  int calls = 0;

  @override
  Future<DeviceAuthResult> authorizeIdentityAction({
    required bool biometricOnly,
  }) async {
    calls++;
    return result;
  }

  @override
  Future<DeviceAuthResult> authorizeBiometricProtection() async => result;

  @override
  Future<List<BiometricType>> enrolledBiometrics() async => const [];
}
