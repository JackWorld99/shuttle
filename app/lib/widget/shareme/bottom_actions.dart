import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';

/// Two buttons side by side at the bottom of a page: the primary one takes 2/3 of the width, on the right, within reach of the thumb.
/// [note] is an optional small line below.
class BottomActions extends StatelessWidget {
  final String secondaryLabel;
  final VoidCallback? onSecondary;
  final String primaryLabel;
  final VoidCallback? onPrimary;
  final String? note;

  /// Both buttons equally wide and neither highlighted
  final bool equal;

  /// The same on every page, so the buttons never move around
  static const padding = EdgeInsets.fromLTRB(16, 8, 16, 16);

  const BottomActions({
    required this.secondaryLabel,
    required this.onSecondary,
    required this.primaryLabel,
    required this.onPrimary,
    this.note,
    this.equal = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: onSecondary,
                  style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text(secondaryLabel, maxLines: 1)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: equal ? 1 : 2,
                child: equal
                    ? ElevatedButton(
                        onPressed: onPrimary,
                        style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(ShareMeSize.buttonH)),
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text(primaryLabel, maxLines: 1)),
                      )
                    : FilledButton(
                        onPressed: onPrimary,
                        child: FittedBox(fit: BoxFit.scaleDown, child: Text(primaryLabel, maxLines: 1)),
                      ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 12),
            Text(
              note!,
              style: ShareMeText.meta.copyWith(color: context.sm.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }
}
