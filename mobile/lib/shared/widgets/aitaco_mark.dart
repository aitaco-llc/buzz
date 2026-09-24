import 'package:flutter/widgets.dart';

/// The aitaco robot-taco mark: white on a teal disc, as on aitaco.co.
class AitacoMark extends StatelessWidget {
  const AitacoMark({super.key, required this.size, this.semanticLabel});

  static const assetPath = 'assets/images/aitaco-mark.png';

  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      assetPath,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: semanticLabel,
      excludeFromSemantics: semanticLabel == null,
    );
  }
}
