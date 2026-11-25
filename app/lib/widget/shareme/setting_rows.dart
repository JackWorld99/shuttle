import 'package:flutter/material.dart';
import 'package:localsend_app/config/shareme_theme.dart';
import 'package:localsend_app/widget/shareme/sm_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Rows with an icon in front: the divider above them starts at the text
abstract interface class SmHasLead {
  bool get hasLead;
}

class SmRowTitle extends StatelessWidget {
  final String title;

  const SmRowTitle(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 22, 16, 8),
      child: Text(title, style: ShareMeText.section.copyWith(color: context.sm.ink2)),
    );
  }
}

class SmRowGroup extends StatelessWidget {
  final List<Widget> children;

  const SmRowGroup({required this.children, super.key});

  static bool _hasLead(Widget w) => w is SmHasLead && (w as SmHasLead).hasLead;

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SmCard(
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: _hasLead(children[i]) ? 70 : 16, color: c.line),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Settings row: [leading icon] title / (description)  [current value] [trailing], min height 56. The main page only uses
/// "title + current value"; descriptions are only used on sub-pages.
class SmRow extends StatelessWidget implements SmHasLead {
  final Widget? lead;
  final String title;
  final TextStyle? titleStyle;
  final String? subtitle;
  final Widget? subtitleWidget;
  final Color? subtitleColor;

  /// The gray current value on the right (e.g. "My devices: automatic")
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SmRow({
    required this.title,
    this.lead,
    this.titleStyle,
    this.subtitle,
    this.subtitleWidget,
    this.subtitleColor,
    this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
    super.key,
  });

  @override
  bool get hasLead => lead != null;

  static double _lineWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + 1;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.sm;
    final sub = subtitleWidget ?? (subtitle == null ? null : Text(subtitle!, style: ShareMeText.meta.copyWith(color: subtitleColor ?? c.ink2)));
    final style = titleStyle ?? ShareMeText.body.copyWith(color: c.ink, fontWeight: FontWeight.w500, fontSize: 15.5);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: style),
        if (sub != null) ...[const SizedBox(height: 2), sub],
      ],
    );
    final row = InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              if (lead != null) ...[lead!, const SizedBox(width: 14)],
              Expanded(
                child: value == null
                    ? text
                    : LayoutBuilder(
                        builder: (context, box) {
                          final valueStyle = ShareMeText.meta.copyWith(color: valueColor ?? c.ink2, fontSize: 14);
                          final shown = Text(value!, style: valueStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
                          // Not enough room for both on one line (small phone, large text): the value goes below instead of
                          // being cut off or squeezing the title
                          if (_lineWidth(context, title, style) + 12 + _lineWidth(context, value!, valueStyle) > box.maxWidth) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [text, const SizedBox(height: 2), shown],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: text),
                              const SizedBox(width: 12),
                              shown,
                            ],
                          );
                        },
                      ),
              ),
              if (trailing != null) ...[const SizedBox(width: 6), trailing!],
            ],
          ),
        ),
      ),
    );
    // Screen readers: one row is one item (a switch belongs to its title; a row with a button of its own keeps that separate)
    return trailing is Switch ? MergeSemantics(child: row) : Semantics(container: true, child: row);
  }
}

/// A small gray note below a group (only used on the "More" and "Background receiving" pages).
class SmRowNote extends StatelessWidget {
  final String text;

  const SmRowNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
      child: Text(text, style: ShareMeText.meta.copyWith(color: context.sm.ink2, fontSize: 12.5)),
    );
  }
}

class SmRowChevron extends StatelessWidget {
  const SmRowChevron({super.key});

  @override
  Widget build(BuildContext context) => Icon(LucideIcons.chevronRight, size: 20, color: context.sm.ink3);
}
