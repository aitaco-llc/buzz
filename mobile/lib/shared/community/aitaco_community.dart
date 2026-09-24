/// This build is bound to one community: aitaco's, on buzz.aitaco.co.
///
/// Pairing, invites and deep links for any other relay are refused, and the
/// app has no community switcher. The storage model still holds a list of
/// communities, so an install carried over from a multi-community build keeps
/// its data; [preferAitacoCommunity] keeps aitaco's entry active.
library;

import 'community.dart';

/// Host of aitaco's relay.
const aitacoRelayHost = 'buzz.aitaco.co';

/// Canonical relay URL, in the HTTPS form pairing payloads carry.
const aitacoRelayUrl = 'https://$aitacoRelayHost';

/// Display name for the community.
const aitacoCommunityName = 'aitaco';

/// Shown when a pairing code, invite or link names a different relay.
const foreignCommunityMessage =
    'This app only connects to the aitaco community on $aitacoRelayHost.';

/// Whether [url] (https, wss, or their plaintext forms) names aitaco's relay
/// on its default port.
bool isAitacoRelayUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  if (uri.scheme != 'https' && uri.scheme != 'wss') return false;
  if (uri.hasPort && uri.port != 443) return false;
  return uri.host.toLowerCase() == aitacoRelayHost;
}

/// Thrown when a pairing code, invite or link names a relay other than
/// aitaco's.
class ForeignCommunityException implements Exception {
  const ForeignCommunityException(this.relayUrl);

  final String relayUrl;

  @override
  String toString() => foreignCommunityMessage;
}

/// Throws [ForeignCommunityException] unless [url] is aitaco's relay.
void requireAitacoRelayUrl(String url) {
  if (!isAitacoRelayUrl(url)) throw ForeignCommunityException(url);
}

/// The id of the community to make active: aitaco's when one is stored,
/// otherwise [activeId] unchanged.
String? preferAitacoCommunity(List<Community> communities, String? activeId) {
  for (final community in communities) {
    if (community.id == activeId && isAitacoRelayUrl(community.relayUrl)) {
      return activeId;
    }
  }
  for (final community in communities) {
    if (isAitacoRelayUrl(community.relayUrl)) return community.id;
  }
  return activeId;
}
