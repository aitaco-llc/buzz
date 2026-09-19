import 'package:flutter/material.dart';

import '../../shared/theme/theme.dart';

class AgeRestrictionPage extends StatelessWidget {
  const AgeRestrictionPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(Grid.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.lock_outline,
                      size: 48,
                      color: context.colors.primary,
                    ),
                  ),
                  const SizedBox(height: Grid.lg),
                  Text(
                    'aitaco is for people 18 and older',
                    textAlign: TextAlign.center,
                    style: context.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Grid.sm),
                  Text(
                    "You must be 18 or older to use aitaco under aitaco's Terms.",
                    textAlign: TextAlign.center,
                    style: context.textTheme.bodyLarge?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
