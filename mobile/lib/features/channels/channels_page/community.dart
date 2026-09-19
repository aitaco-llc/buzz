part of '../channels_page.dart';

// This build is bound to aitaco's community, so the header names it and shows
// its mark. There is no switcher behind it.

class _CommunityIndicator extends StatelessWidget {
  const _CommunityIndicator();

  @override
  Widget build(BuildContext context) {
    return const AitacoMark(size: _kTopSectionCommunityAvatarSize);
  }
}

class _CommunityHeaderTitle extends ConsumerWidget {
  final TextStyle? style;

  const _CommunityHeaderTitle({this.style});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final community = ref.watch(activeCommunityProvider).value;
    final stored = community?.name.trim();
    final title = community == null || isAitacoRelayUrl(community.relayUrl)
        ? aitacoCommunityName
        : (stored == null || stored.isEmpty ? 'Community' : stored);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: Grid.xxs),
        child: Text(
          title,
          key: const Key('community-header-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );
  }
}
