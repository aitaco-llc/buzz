import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../shared/clipboard_utils.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/buzz_loading_indicator.dart';
import '../../shared/widgets/frosted_app_bar.dart';
import '../../shared/widgets/frosted_scaffold.dart';
import 'add_device_provider.dart';
import 'pairing_lifecycle_hook.dart';

/// Settings → Add a device: this phone shows a pairing code and, after the
/// six-digit check and Face ID or the passcode, sends its identity to another
/// device — Desktop, an iPad, another phone, or another app on this phone.
class AddDevicePage extends HookConsumerWidget {
  const AddDevicePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(addDeviceProvider);
    final notifier = ref.read(addDeviceProvider.notifier);

    useEffect(() {
      unawaited(Future.microtask(notifier.start));
      return null;
    }, const []);

    usePairingLifecycle(
      active: state.isActive,
      onBackgrounded: notifier.appBackgrounded,
      onResumed: notifier.appResumed,
    );

    final body = switch (state.status) {
      AddDeviceStatus.idle || AddDeviceStatus.preparing => const _Busy(
        label: 'Getting a pairing code…',
      ),
      AddDeviceStatus.waitingForDevice => _CodeView(uri: state.pairingUri!),
      AddDeviceStatus.confirmingSas => _SasView(
        sasCode: state.sasCode!,
        busy: state.authorizationInProgress,
        errorMessage: state.errorMessage,
        onConfirm: () => unawaited(notifier.confirmSas()),
        onDeny: notifier.denySas,
      ),
      AddDeviceStatus.sending => const _Busy(
        label: 'Sent. Waiting for your other device…',
      ),
      AddDeviceStatus.success => _Result(
        icon: LucideIcons.circleCheck,
        title: 'Your other device is signed in',
        message: 'It now uses this aitaco identity.',
        actionLabel: 'Done',
        onAction: () => Navigator.of(context).maybePop(),
      ),
      AddDeviceStatus.sentUnconfirmed => _Result(
        icon: LucideIcons.send,
        title: 'Identity sent',
        message:
            'Your other device did not confirm in time. Check that it is signed in.',
        actionLabel: 'Done',
        onAction: () => Navigator.of(context).maybePop(),
      ),
      AddDeviceStatus.error => _Result(
        icon: LucideIcons.circleAlert,
        title: 'Pairing stopped',
        message: state.errorMessage ?? 'Something went wrong.',
        actionLabel: 'Try again',
        onAction: () => unawaited(notifier.start()),
      ),
    };

    return FrostedScaffold(
      useUtilitySurfaceTheme: true,
      appBar: const FrostedAppBar(
        centerTitle: true,
        title: Text('Add a device'),
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            Grid.gutter,
            frostedAppBarHeight(context) + Grid.sm,
            Grid.gutter,
            Grid.lg,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}

class _CodeView extends StatelessWidget {
  const _CodeView({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in another device as you',
          textAlign: TextAlign.center,
          style: context.textTheme.titleLarge,
        ),
        const SizedBox(height: Grid.xs),
        Text(
          'On the other device, open aitaco or Buzz and choose to scan a '
          'pairing code. For another app on this phone, copy the code and '
          'paste it there.',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: Grid.md),
        Center(
          child: Container(
            key: const ValueKey('add-device-qr'),
            padding: const EdgeInsets.all(Grid.xs),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: uri,
              size: 240,
              backgroundColor: Colors.white,
              semanticsLabel: 'Pairing QR code',
            ),
          ),
        ),
        const SizedBox(height: Grid.md),
        FilledButton.tonalIcon(
          key: const ValueKey('add-device-copy-code'),
          onPressed: () =>
              copyToClipboard(context, uri, message: 'Pairing code copied'),
          icon: const Icon(LucideIcons.copy),
          label: const Text('Copy pairing code'),
        ),
        const SizedBox(height: Grid.xs),
        Text(
          'The code works once, for two minutes.',
          textAlign: TextAlign.center,
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SasView extends StatelessWidget {
  const _SasView({
    required this.sasCode,
    required this.busy,
    required this.errorMessage,
    required this.onConfirm,
    required this.onDeny,
  });

  final String sasCode;
  final bool busy;
  final String? errorMessage;
  final VoidCallback onConfirm;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Does your other device show this code?',
          textAlign: TextAlign.center,
          style: context.textTheme.titleLarge,
        ),
        const SizedBox(height: Grid.xs),
        Text(
          'If it matches, your aitaco identity goes to that device and it '
          'can act as you. Only continue if you started this pairing.',
          textAlign: TextAlign.center,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Grid.md),
        Semantics(
          label:
              'Confirmation code ${sasCode.substring(0, 3)} ${sasCode.substring(3)}',
          child: ExcludeSemantics(
            child: Text(
              '${sasCode.substring(0, 3)} ${sasCode.substring(3)}',
              key: const ValueKey('add-device-sas'),
              textAlign: TextAlign.center,
              style: context.textTheme.displayMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 2,
              ),
            ),
          ),
        ),
        if (errorMessage != null) ...[
          const SizedBox(height: Grid.xs),
          Text(
            errorMessage!,
            textAlign: TextAlign.center,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.error,
            ),
          ),
        ],
        const SizedBox(height: Grid.md),
        FilledButton.icon(
          key: const ValueKey('add-device-confirm'),
          onPressed: busy
              ? null
              : () {
                  unawaited(HapticFeedback.lightImpact());
                  onConfirm();
                },
          icon: const Icon(LucideIcons.check),
          label: const Text('Codes match'),
        ),
        const SizedBox(height: Grid.xxs),
        TextButton(
          key: const ValueKey('add-device-deny'),
          onPressed: busy ? null : onDeny,
          child: const Text('They don’t match'),
        ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Grid.xl),
      child: Column(
        children: [
          BuzzLoadingIndicator(size: 40, semanticLabel: label),
          const SizedBox(height: Grid.sm),
          Text(
            label,
            textAlign: TextAlign.center,
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: Grid.lg),
        Icon(icon, size: 40, color: context.colors.primary),
        const SizedBox(height: Grid.sm),
        Text(
          title,
          textAlign: TextAlign.center,
          style: context.textTheme.titleLarge,
        ),
        const SizedBox(height: Grid.xs),
        Text(
          message,
          textAlign: TextAlign.center,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Grid.lg),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}
