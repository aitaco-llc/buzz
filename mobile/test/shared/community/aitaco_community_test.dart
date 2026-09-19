import 'package:flutter_test/flutter_test.dart';

import 'package:buzz/shared/community/aitaco_community.dart';
import 'package:buzz/shared/community/community.dart';

void main() {
  group('isAitacoRelayUrl', () {
    test('accepts aitaco relay origins in either TLS scheme', () {
      expect(isAitacoRelayUrl('https://buzz.aitaco.co'), isTrue);
      expect(isAitacoRelayUrl('wss://buzz.aitaco.co'), isTrue);
      expect(isAitacoRelayUrl('wss://BUZZ.aitaco.co/'), isTrue);
      expect(isAitacoRelayUrl('https://buzz.aitaco.co:443'), isTrue);
    });

    test('rejects other hosts, plaintext, and other ports', () {
      expect(isAitacoRelayUrl('https://relay.example.com'), isFalse);
      expect(isAitacoRelayUrl('https://buzz.aitaco.co.evil.com'), isFalse);
      expect(isAitacoRelayUrl('https://evil.com/buzz.aitaco.co'), isFalse);
      expect(isAitacoRelayUrl('ws://buzz.aitaco.co'), isFalse);
      expect(isAitacoRelayUrl('http://buzz.aitaco.co'), isFalse);
      expect(isAitacoRelayUrl('https://buzz.aitaco.co:8443'), isFalse);
      expect(isAitacoRelayUrl('not a url'), isFalse);
    });

    test('requireAitacoRelayUrl throws for a foreign relay', () {
      expect(
        () => requireAitacoRelayUrl('wss://relay.example.com'),
        throwsA(isA<ForeignCommunityException>()),
      );
      requireAitacoRelayUrl('wss://buzz.aitaco.co');
    });
  });

  group('preferAitacoCommunity', () {
    final foreign = Community.create(
      name: 'other',
      relayUrl: 'https://relay.example.com',
    );
    final aitaco = Community.create(
      name: 'buzz',
      relayUrl: 'https://buzz.aitaco.co',
    );

    test('moves a carried-over install onto aitaco', () {
      expect(preferAitacoCommunity([foreign, aitaco], foreign.id), aitaco.id);
      expect(preferAitacoCommunity([foreign, aitaco], null), aitaco.id);
    });

    test('keeps aitaco when it is already active', () {
      expect(preferAitacoCommunity([aitaco, foreign], aitaco.id), aitaco.id);
    });

    test('leaves the active id alone when aitaco is not stored', () {
      expect(preferAitacoCommunity([foreign], foreign.id), foreign.id);
      expect(preferAitacoCommunity([], null), isNull);
    });
  });

  test('names the aitaco relay "aitaco"', () {
    expect(Community.nameFromUrl('https://buzz.aitaco.co'), 'aitaco');
    expect(Community.nameFromUrl('https://relay.example.com'), 'relay');
  });
}
