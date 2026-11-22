import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Registers the SIL OFL 1.1 license of the bundled font, and the Apache-2.0 license of LocalSend (which Shuttle is based on),
/// with Flutter's open-source licenses page. The OFL requires the license and copyright notice to ship with the font
/// (files in assets/fonts/).
void registerShareMeFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['JetBrains Mono (Latin subset)'],
      await rootBundle.loadString('assets/fonts/OFL-JetBrainsMono.txt'),
    );
    // Shuttle is derived from LocalSend (Apache-2.0 section 4: ship a copy of the license and keep the original copyright notices)
    yield LicenseEntryWithLineBreaks(
      const ['LocalSend'],
      await rootBundle.loadString('assets/licenses/LocalSend-LICENSE.txt'),
    );
  });
}
