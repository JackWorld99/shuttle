import 'package:flutter/material.dart';
import 'package:localsend_app/gen/assets.gen.dart';

class LocalSendLogo extends StatelessWidget {
  final bool withText;

  const LocalSendLogo({required this.withText});

  @override
  Widget build(BuildContext context) {
    // Shuttle: the new logo is already colored (dark background, gradient "S"), so it is no longer tinted with the theme color
    final logo = Assets.img.logo512.image(
      width: 160,
      height: 160,
    );

    if (withText) {
      return Column(
        children: [
          logo,
          const SizedBox(height: 12),
          const Text(
            'Shuttle',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else {
      return logo;
    }
  }
}
