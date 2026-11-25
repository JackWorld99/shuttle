///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element

class Translations with BaseTranslations<AppLocale, Translations> {
  /// Returns the current translations of the given [context].
  ///
  /// Usage:
  /// final t = Translations.of(context);
  static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

  /// You can call this constructor and build your own translation instance of this locale.
  /// Constructing via the enum [AppLocale.build] is preferred.
  Translations({
    Map<String, Node>? overrides,
    PluralResolver? cardinalResolver,
    PluralResolver? ordinalResolver,
    TranslationMetadata<AppLocale, Translations>? meta,
  }) : assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
       $meta =
           meta ??
           TranslationMetadata(
             locale: AppLocale.en,
             overrides: overrides ?? {},
             cardinalResolver: cardinalResolver,
             ordinalResolver: ordinalResolver,
           );

  /// Metadata for the translations of <en>.
  @override
  final TranslationMetadata<AppLocale, Translations> $meta;

  late final Translations _root = this; // ignore: unused_field

  Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

  // Translations

  /// en: 'Shuttle'
  String get appName => 'Shuttle';

  late final Translations$shareme$en shareme = Translations$shareme$en.internal(_root);
  late final Translations$general$en general = Translations$general$en.internal(_root);
  late final Translations$receiveTab$en receiveTab = Translations$receiveTab$en.internal(_root);
  late final Translations$sendTab$en sendTab = Translations$sendTab$en.internal(_root);
  late final Translations$settingsTab$en settingsTab = Translations$settingsTab$en.internal(_root);
  late final Translations$troubleshootPage$en troubleshootPage = Translations$troubleshootPage$en.internal(_root);
  late final Translations$networkInterfacesPage$en networkInterfacesPage = Translations$networkInterfacesPage$en.internal(_root);
  late final Translations$receiveHistoryPage$en receiveHistoryPage = Translations$receiveHistoryPage$en.internal(_root);
  late final Translations$apkPickerPage$en apkPickerPage = Translations$apkPickerPage$en.internal(_root);
  late final Translations$selectedFilesPage$en selectedFilesPage = Translations$selectedFilesPage$en.internal(_root);
  late final Translations$deviceDetailsPage$en deviceDetailsPage = Translations$deviceDetailsPage$en.internal(_root);
  late final Translations$verifyPage$en verifyPage = Translations$verifyPage$en.internal(_root);
  late final Translations$receivePage$en receivePage = Translations$receivePage$en.internal(_root);
  late final Translations$receiveOptionsPage$en receiveOptionsPage = Translations$receiveOptionsPage$en.internal(_root);
  late final Translations$sendPage$en sendPage = Translations$sendPage$en.internal(_root);
  late final Translations$progressPage$en progressPage = Translations$progressPage$en.internal(_root);
  late final Translations$webSharePage$en webSharePage = Translations$webSharePage$en.internal(_root);
  late final Translations$webReceivePage$en webReceivePage = Translations$webReceivePage$en.internal(_root);
  late final Translations$aboutPage$en aboutPage = Translations$aboutPage$en.internal(_root);
  late final Translations$donationPage$en donationPage = Translations$donationPage$en.internal(_root);
  late final Translations$changelogPage$en changelogPage = Translations$changelogPage$en.internal(_root);
  late final Translations$whatsNewPage$en whatsNewPage = Translations$whatsNewPage$en.internal(_root);
  late final Translations$aliasGenerator$en aliasGenerator = Translations$aliasGenerator$en.internal(_root);
  late final Translations$dialogs$en dialogs = Translations$dialogs$en.internal(_root);
  late final Translations$sanitization$en sanitization = Translations$sanitization$en.internal(_root);
  late final Translations$tray$en tray = Translations$tray$en.internal(_root);
  late final Translations$web$en web = Translations$web$en.internal(_root);
  late final Translations$assetPicker$en assetPicker = Translations$assetPicker$en.internal(_root);
}

// Path: shareme
class Translations$shareme$en {
  Translations$shareme$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$shareme$nav$en nav = Translations$shareme$nav$en.internal(_root);
  late final Translations$shareme$time$en time = Translations$shareme$time$en.internal(_root);
  late final Translations$shareme$home$en home = Translations$shareme$home$en.internal(_root);
  late final Translations$shareme$safety$en safety = Translations$shareme$safety$en.internal(_root);
  late final Translations$shareme$send$en send = Translations$shareme$send$en.internal(_root);
  late final Translations$shareme$text$en text = Translations$shareme$text$en.internal(_root);
  late final Translations$shareme$receive$en receive = Translations$shareme$receive$en.internal(_root);
  late final Translations$shareme$history$en history = Translations$shareme$history$en.internal(_root);
  late final Translations$shareme$pair$en pair = Translations$shareme$pair$en.internal(_root);
  late final Translations$shareme$settings$en settings = Translations$shareme$settings$en.internal(_root);
  late final Translations$shareme$update$en update = Translations$shareme$update$en.internal(_root);
}

// Path: general
class Translations$general$en {
  Translations$general$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Accept'
  String get accept => 'Accept';

  /// en: 'Accepted'
  String get accepted => 'Accepted';

  /// en: 'Add'
  String get add => 'Add';

  /// en: 'Advanced'
  String get advanced => 'Advanced';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Close'
  String get close => 'Close';

  /// en: 'Confirm'
  String get confirm => 'Confirm';

  /// en: 'Continue'
  String get continueStr => 'Continue';

  /// en: 'Copy'
  String get copy => 'Copy';

  /// en: 'Copied to Clipboard'
  String get copiedToClipboard => 'Copied to Clipboard';

  /// en: 'Decline'
  String get decline => 'Decline';

  /// en: 'Done'
  String get done => 'Done';

  /// en: 'Delete'
  String get delete => 'Delete';

  /// en: 'Edit'
  String get edit => 'Edit';

  /// en: 'Error'
  String get error => 'Error';

  /// en: 'Example'
  String get example => 'Example';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'Finished'
  String get finished => 'Finished';

  /// en: 'Hide'
  String get hide => 'Hide';

  /// en: 'Off'
  String get off => 'Off';

  /// en: 'Offline'
  String get offline => 'Offline';

  /// en: 'On'
  String get on => 'On';

  /// en: 'Online'
  String get online => 'Online';

  /// en: 'Open'
  String get open => 'Open';

  /// en: 'Queue'
  String get queue => 'Queue';

  /// en: 'Quick Save'
  String get quickSave => 'Quick Save';

  /// en: 'Quick Save for "Favorites"'
  String get quickSaveFromFavorites => 'Quick Save for "Favorites"';

  /// en: 'Renamed'
  String get renamed => 'Renamed';

  /// en: 'Undo changes'
  String get reset => 'Undo changes';

  /// en: 'Restart'
  String get restart => 'Restart';

  /// en: 'Settings'
  String get settings => 'Settings';

  /// en: 'Skipped'
  String get skipped => 'Skipped';

  /// en: 'Start'
  String get start => 'Start';

  /// en: 'Stop'
  String get stop => 'Stop';

  /// en: 'Save'
  String get save => 'Save';

  /// en: 'Unchanged'
  String get unchanged => 'Unchanged';

  /// en: 'Unknown'
  String get unknown => 'Unknown';

  /// en: 'No items in Clipboard.'
  String get noItemInClipboard => 'No items in Clipboard.';
}

// Path: receiveTab
class Translations$receiveTab$en {
  Translations$receiveTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive'
  String get title => 'Receive';

  late final Translations$receiveTab$infoBox$en infoBox = Translations$receiveTab$infoBox$en.internal(_root);
  late final Translations$receiveTab$quickSave$en quickSave = Translations$receiveTab$quickSave$en.internal(_root);

  /// en: 'Receive via link'
  String get link => 'Receive via link';
}

// Path: sendTab
class Translations$sendTab$en {
  Translations$sendTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send'
  String get title => 'Send';

  late final Translations$sendTab$selection$en selection = Translations$sendTab$selection$en.internal(_root);
  late final Translations$sendTab$picker$en picker = Translations$sendTab$picker$en.internal(_root);

  /// en: 'You can also use the "Share" feature of your mobile device to select files more easily.'
  String get shareIntentInfo => 'You can also use the "Share" feature of your mobile device to select files more easily.';

  /// en: 'Nearby devices'
  String get nearbyDevices => 'Nearby devices';

  /// en: 'This Device'
  String get thisDevice => 'This Device';

  /// en: 'Search devices'
  String get scan => 'Search devices';

  /// en: 'Manual sending'
  String get manualSending => 'Manual sending';

  /// en: 'Send mode'
  String get sendMode => 'Send mode';

  late final Translations$sendTab$sendModes$en sendModes = Translations$sendTab$sendModes$en.internal(_root);

  /// en: 'Explanation'
  String get sendModeHelp => 'Explanation';

  /// en: 'Please ensure that the desired target is also on the same Wi-Fi network.'
  String get help => 'Please ensure that the desired target is also on the same Wi-Fi network.';

  /// en: 'Place items to share.'
  String get placeItems => 'Place items to share.';
}

// Path: settingsTab
class Translations$settingsTab$en {
  Translations$settingsTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Settings'
  String get title => 'Settings';

  late final Translations$settingsTab$general$en general = Translations$settingsTab$general$en.internal(_root);
  late final Translations$settingsTab$receive$en receive = Translations$settingsTab$receive$en.internal(_root);
  late final Translations$settingsTab$send$en send = Translations$settingsTab$send$en.internal(_root);
  late final Translations$settingsTab$network$en network = Translations$settingsTab$network$en.internal(_root);
  late final Translations$settingsTab$other$en other = Translations$settingsTab$other$en.internal(_root);

  /// en: 'Advanced settings'
  String get advancedSettings => 'Advanced settings';
}

// Path: troubleshootPage
class Translations$troubleshootPage$en {
  Translations$troubleshootPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Troubleshoot'
  String get title => 'Troubleshoot';

  /// en: 'Does the app not work as expected? Here you can find some common solutions to problems.'
  String get subTitle => 'Does the app not work as expected? Here you can find some common solutions to problems.';

  /// en: 'Solution:'
  String get solution => 'Solution:';

  /// en: 'Fix automatically'
  String get fixButton => 'Fix automatically';

  late final Translations$troubleshootPage$firewall$en firewall = Translations$troubleshootPage$firewall$en.internal(_root);
  late final Translations$troubleshootPage$noDiscovery$en noDiscovery = Translations$troubleshootPage$noDiscovery$en.internal(_root);
  late final Translations$troubleshootPage$noConnection$en noConnection = Translations$troubleshootPage$noConnection$en.internal(_root);
}

// Path: networkInterfacesPage
class Translations$networkInterfacesPage$en {
  Translations$networkInterfacesPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Network Interfaces'
  String get title => 'Network Interfaces';

  /// en: 'By default, Shuttle uses all available network interfaces. You can exclude unwanted networks here. You need to restart the server to apply the changes.'
  String get info =>
      'By default, Shuttle uses all available network interfaces. You can exclude unwanted networks here. You need to restart the server to apply the changes.';

  /// en: 'Preview'
  String get preview => 'Preview';

  /// en: 'Whitelist'
  String get whitelist => 'Whitelist';

  /// en: 'Blacklist'
  String get blacklist => 'Blacklist';
}

// Path: receiveHistoryPage
class Translations$receiveHistoryPage$en {
  Translations$receiveHistoryPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'History'
  String get title => 'History';

  /// en: 'Open folder'
  String get openFolder => 'Open folder';

  /// en: 'Delete history'
  String get deleteHistory => 'Delete history';

  /// en: 'The history is empty.'
  String get empty => 'The history is empty.';

  late final Translations$receiveHistoryPage$entryActions$en entryActions = Translations$receiveHistoryPage$entryActions$en.internal(_root);
}

// Path: apkPickerPage
class Translations$apkPickerPage$en {
  Translations$apkPickerPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Apps (APK)'
  String get title => 'Apps (APK)';

  /// en: 'Exclude system apps'
  String get excludeSystemApps => 'Exclude system apps';

  /// en: 'Exclude non-launchable apps'
  String get excludeAppsWithoutLaunchIntent => 'Exclude non-launchable apps';

  /// en: '{n} Apps'
  String apps({required Object n}) => '${n} Apps';
}

// Path: selectedFilesPage
class Translations$selectedFilesPage$en {
  Translations$selectedFilesPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Delete all'
  String get deleteAll => 'Delete all';
}

// Path: deviceDetailsPage
class Translations$deviceDetailsPage$en {
  Translations$deviceDetailsPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Device Details'
  String get title => 'Device Details';

  /// en: 'Favorite'
  String get favorite => 'Favorite';

  /// en: 'Verify'
  String get verify => 'Verify';

  late final Translations$deviceDetailsPage$info$en info = Translations$deviceDetailsPage$info$en.internal(_root);
  late final Translations$deviceDetailsPage$logs$en logs = Translations$deviceDetailsPage$logs$en.internal(_root);
}

// Path: verifyPage
class Translations$verifyPage$en {
  Translations$verifyPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Verify'
  String get title => 'Verify';

  /// en: 'Icons'
  String get icons => 'Icons';

  /// en: 'Text'
  String get text => 'Text';

  /// en: 'Does it look the same on the other device?'
  String get question => 'Does it look the same on the other device?';
}

// Path: receivePage
class Translations$receivePage$en {
  Translations$receivePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: '(one) {wants to send you a file} (other) {wants to send you {n} files}'
  String subTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'wants to send you a file',
    other: 'wants to send you ${n} files',
  );

  /// en: 'sent you a message:'
  String get subTitleMessage => 'sent you a message:';

  /// en: 'sent you a link:'
  String get subTitleLink => 'sent you a link:';

  /// en: 'The sender has canceled the request.'
  String get canceled => 'The sender has canceled the request.';
}

// Path: receiveOptionsPage
class Translations$receiveOptionsPage$en {
  Translations$receiveOptionsPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Options'
  String get title => 'Options';

  /// en: 'Save to folder'
  String get destination => _root.settingsTab.receive.destination;

  /// en: '(Shuttle folder)'
  String get appDirectory => '(Shuttle folder)';

  /// en: 'Save media to gallery'
  String get saveToGallery => _root.settingsTab.receive.saveToGallery;

  /// en: 'Turned off automatically because there are folders.'
  String get saveToGalleryOff => 'Turned off automatically because there are folders.';
}

// Path: sendPage
class Translations$sendPage$en {
  Translations$sendPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Calculating checksum ({curr} / {n})'
  String calculatingChecksum({required Object curr, required Object n}) => 'Calculating checksum (${curr} / ${n})';

  /// en: 'Waiting for response…'
  String get waiting => 'Waiting for response…';

  /// en: 'The recipient has rejected the request.'
  String get rejected => 'The recipient has rejected the request.';

  /// en: 'Too many attempts'
  String get tooManyAttempts => _root.web.tooManyAttempts;

  /// en: 'The recipient is busy with another request.'
  String get busy => 'The recipient is busy with another request.';
}

// Path: progressPage
class Translations$progressPage$en {
  Translations$progressPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Sending files'
  String get titleSending => 'Sending files';

  /// en: 'Receiving files'
  String get titleReceiving => 'Receiving files';

  /// en: 'Saved in Photos'
  String get savedToGallery => 'Saved in Photos';

  late final Translations$progressPage$total$en total = Translations$progressPage$total$en.internal(_root);
  late final Translations$progressPage$remainingTime$en remainingTime = Translations$progressPage$remainingTime$en.internal(_root);
}

// Path: webSharePage
class Translations$webSharePage$en {
  Translations$webSharePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Share via link'
  String get title => 'Share via link';

  /// en: 'Starting server…'
  String get loading => 'Starting server…';

  /// en: 'Stopping server…'
  String get stopping => 'Stopping server…';

  /// en: 'An error occurred while starting the server.'
  String get error => 'An error occurred while starting the server.';

  /// en: '(one) {Open this link in your browser:} (other) {Open one of these links in your browser:}'
  String openLink({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Open this link in your browser:',
    other: 'Open one of these links in your browser:',
  );

  /// en: 'Requests'
  String get requests => 'Requests';

  /// en: 'No requests yet.'
  String get noRequests => 'No requests yet.';

  /// en: 'Encryption'
  String get encryption => _root.settingsTab.network.encryption;

  /// en: 'Automatically accept requests'
  String get autoAccept => 'Automatically accept requests';

  /// en: 'Require PIN'
  String get requirePin => 'Require PIN';

  /// en: 'The PIN is "{pin}"'
  String pinHint({required Object pin}) => 'The PIN is "${pin}"';

  /// en: 'Shuttle uses a self-signed certificate. You need to accept it in your browser.'
  String get encryptionHint => 'Shuttle uses a self-signed certificate. You need to accept it in your browser.';

  /// en: 'Pending requests: {n}'
  String pendingRequests({required Object n}) => 'Pending requests: ${n}';
}

// Path: webReceivePage
class Translations$webReceivePage$en {
  Translations$webReceivePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive via link'
  String get title => 'Receive via link';
}

// Path: aboutPage
class Translations$aboutPage$en {
  Translations$aboutPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'About Shuttle'
  String get title => 'About Shuttle';

  List<String> get description => [
    'Shuttle lets you securely share original photos, videos, files, links and text between your own devices over your local network, without needing an internet connection.',
    'Shuttle is built on LocalSend, a free and open-source project (Apache-2.0). Thanks to the LocalSend authors and contributors listed below.',
  ];

  /// en: 'Author'
  String get author => 'Author';

  /// en: 'Contributors'
  String get contributors => 'Contributors';

  /// en: 'Packagers'
  String get packagers => 'Packagers';

  /// en: 'Translators'
  String get translators => 'Translators';
}

// Path: donationPage
class Translations$donationPage$en {
  Translations$donationPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Donate'
  String get title => 'Donate';

  /// en: 'LocalSend is free, open-source and without any ads. If you like the app, you can support the development with a donation.'
  String get info => 'LocalSend is free, open-source and without any ads. If you like the app, you can support the development with a donation.';

  /// en: 'Donate {amount}'
  String donate({required Object amount}) => 'Donate ${amount}';

  /// en: 'Thank you very much!'
  String get thanks => 'Thank you very much!';

  /// en: 'Restore purchase'
  String get restore => 'Restore purchase';
}

// Path: changelogPage
class Translations$changelogPage$en {
  Translations$changelogPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Changelog'
  String get title => 'Changelog';
}

// Path: whatsNewPage
class Translations$whatsNewPage$en {
  Translations$whatsNewPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'What's new in {version}'
  String title({required Object version}) => 'What\'s new in ${version}';

  late final Translations$whatsNewPage$changes$en changes = Translations$whatsNewPage$changes$en.internal(_root);
}

// Path: aliasGenerator
class Translations$aliasGenerator$en {
  Translations$aliasGenerator$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  List<String> get adjectives => [
    'Adorable',
    'Beautiful',
    'Big',
    'Bright',
    'Clean',
    'Clever',
    'Cool',
    'Cute',
    'Cunning',
    'Determined',
    'Energetic',
    'Efficient',
    'Fantastic',
    'Fast',
    'Fine',
    'Fresh',
    'Good',
    'Gorgeous',
    'Great',
    'Handsome',
    'Hot',
    'Kind',
    'Lovely',
    'Mystic',
    'Neat',
    'Nice',
    'Patient',
    'Pretty',
    'Powerful',
    'Rich',
    'Secret',
    'Smart',
    'Solid',
    'Special',
    'Strategic',
    'Strong',
    'Tidy',
    'Wise',
  ];
  List<String> get fruits => [
    'Apple',
    'Avocado',
    'Banana',
    'Blackberry',
    'Blueberry',
    'Broccoli',
    'Carrot',
    'Cherry',
    'Coconut',
    'Grape',
    'Lemon',
    'Lettuce',
    'Mango',
    'Melon',
    'Mushroom',
    'Onion',
    'Orange',
    'Papaya',
    'Peach',
    'Pear',
    'Pineapple',
    'Potato',
    'Pumpkin',
    'Raspberry',
    'Strawberry',
    'Tomato',
  ];

  /// In some languages, the adjective must be last.
  ///
  /// en: '{adjective} {fruit}'
  String combination({required Object adjective, required Object fruit}) => '${adjective} ${fruit}';
}

// Path: dialogs
class Translations$dialogs$en {
  Translations$dialogs$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$dialogs$addFile$en addFile = Translations$dialogs$addFile$en.internal(_root);
  late final Translations$dialogs$openFile$en openFile = Translations$dialogs$openFile$en.internal(_root);
  late final Translations$dialogs$addressInput$en addressInput = Translations$dialogs$addressInput$en.internal(_root);
  late final Translations$dialogs$cancelSession$en cancelSession = Translations$dialogs$cancelSession$en.internal(_root);
  late final Translations$dialogs$cannotOpenFile$en cannotOpenFile = Translations$dialogs$cannotOpenFile$en.internal(_root);
  late final Translations$dialogs$encryptionDisabledNotice$en encryptionDisabledNotice = Translations$dialogs$encryptionDisabledNotice$en.internal(
    _root,
  );
  late final Translations$dialogs$errorDialog$en errorDialog = Translations$dialogs$errorDialog$en.internal(_root);
  late final Translations$dialogs$favoriteDialog$en favoriteDialog = Translations$dialogs$favoriteDialog$en.internal(_root);
  late final Translations$dialogs$favoriteDeleteDialog$en favoriteDeleteDialog = Translations$dialogs$favoriteDeleteDialog$en.internal(_root);
  late final Translations$dialogs$favoriteEditDialog$en favoriteEditDialog = Translations$dialogs$favoriteEditDialog$en.internal(_root);
  late final Translations$dialogs$fileInfo$en fileInfo = Translations$dialogs$fileInfo$en.internal(_root);
  late final Translations$dialogs$fileNameInput$en fileNameInput = Translations$dialogs$fileNameInput$en.internal(_root);
  late final Translations$dialogs$historyClearDialog$en historyClearDialog = Translations$dialogs$historyClearDialog$en.internal(_root);
  late final Translations$dialogs$localNetworkUnauthorized$en localNetworkUnauthorized = Translations$dialogs$localNetworkUnauthorized$en.internal(
    _root,
  );
  late final Translations$dialogs$messageInput$en messageInput = Translations$dialogs$messageInput$en.internal(_root);
  late final Translations$dialogs$noFiles$en noFiles = Translations$dialogs$noFiles$en.internal(_root);
  late final Translations$dialogs$noPermission$en noPermission = Translations$dialogs$noPermission$en.internal(_root);
  late final Translations$dialogs$notAvailableOnPlatform$en notAvailableOnPlatform = Translations$dialogs$notAvailableOnPlatform$en.internal(_root);
  late final Translations$dialogs$qr$en qr = Translations$dialogs$qr$en.internal(_root);
  late final Translations$dialogs$quickActions$en quickActions = Translations$dialogs$quickActions$en.internal(_root);
  late final Translations$dialogs$quickSaveNotice$en quickSaveNotice = Translations$dialogs$quickSaveNotice$en.internal(_root);
  late final Translations$dialogs$quickSaveFromFavoritesNotice$en quickSaveFromFavoritesNotice =
      Translations$dialogs$quickSaveFromFavoritesNotice$en.internal(_root);
  late final Translations$dialogs$pin$en pin = Translations$dialogs$pin$en.internal(_root);
  late final Translations$dialogs$sendModeHelp$en sendModeHelp = Translations$dialogs$sendModeHelp$en.internal(_root);
  late final Translations$dialogs$zoom$en zoom = Translations$dialogs$zoom$en.internal(_root);
}

// Path: sanitization
class Translations$sanitization$en {
  Translations$sanitization$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Filename cannot be empty'
  String get empty => 'Filename cannot be empty';

  /// en: 'Filename contains invalid characters'
  String get invalid => 'Filename contains invalid characters';
}

// Path: tray
class Translations$tray$en {
  Translations$tray$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open'
  String get open => _root.general.open;

  /// en: 'Quit Shuttle'
  String get close => 'Quit Shuttle';

  /// en: 'Exit'
  String get closeWindows => 'Exit';
}

// Path: web
class Translations$web$en {
  Translations$web$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Waiting for response…'
  String get waiting => _root.sendPage.waiting;

  /// en: 'Enter PIN'
  String get enterPin => 'Enter PIN';

  /// en: 'Invalid PIN'
  String get invalidPin => 'Invalid PIN';

  /// en: 'Too many attempts'
  String get tooManyAttempts => 'Too many attempts';

  /// en: 'Rejected'
  String get rejected => 'Rejected';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'File name'
  String get fileName => 'File name';

  /// en: 'Size'
  String get size => 'Size';
}

// Path: assetPicker
class Translations$assetPicker$en {
  Translations$assetPicker$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Confirm'
  String get confirm => 'Confirm';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Edit'
  String get edit => 'Edit';

  /// en: 'GIF'
  String get gifIndicator => 'GIF';

  /// en: 'Load failed'
  String get loadFailed => 'Load failed';

  /// en: 'Origin'
  String get original => 'Origin';

  /// en: 'Preview'
  String get preview => 'Preview';

  /// en: 'Select'
  String get select => 'Select';

  /// en: 'Empty list'
  String get emptyList => 'Empty list';

  /// en: 'Unsupported file type.'
  String get unSupportedAssetType => 'Unsupported file type.';

  /// en: 'Unable to access all files on the device'
  String get unableToAccessAll => 'Unable to access all files on the device';

  /// en: 'Only view files and albums accessible to the app.'
  String get viewingLimitedAssetsTip => 'Only view files and albums accessible to the app.';

  /// en: 'Click to update accessible files'
  String get changeAccessibleLimitedAssets => 'Click to update accessible files';

  /// en: 'App can only access some files on the device. Go to system settings and allow the app to access all media on the device.'
  String get accessAllTip =>
      'App can only access some files on the device. Go to system settings and allow the app to access all media on the device.';

  /// en: 'Go to system settings'
  String get goToSystemSettings => 'Go to system settings';

  /// en: 'Continue with limited access'
  String get accessLimitedAssets => 'Continue with limited access';

  /// en: 'Accessible files'
  String get accessiblePathName => 'Accessible files';

  /// en: 'Audio'
  String get sTypeAudioLabel => 'Audio';

  /// en: 'Image'
  String get sTypeImageLabel => 'Image';

  /// en: 'Video'
  String get sTypeVideoLabel => 'Video';

  /// en: 'Other media'
  String get sTypeOtherLabel => 'Other media';

  /// en: 'play'
  String get sActionPlayHint => 'play';

  /// en: 'preview'
  String get sActionPreviewHint => 'preview';

  /// en: 'select'
  String get sActionSelectHint => 'select';

  /// en: 'change path'
  String get sActionSwitchPathLabel => 'change path';

  /// en: 'use camera'
  String get sActionUseCameraHint => 'use camera';

  /// en: 'duration'
  String get sNameDurationLabel => 'duration';

  /// en: 'count'
  String get sUnitAssetCountLabel => 'count';
}

// Path: shareme.nav
class Translations$shareme$nav$en {
  Translations$shareme$nav$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Transfer'
  String get transfer => 'Transfer';

  /// en: 'History'
  String get history => 'History';

  /// en: 'Settings'
  String get settings => 'Settings';
}

// Path: shareme.time
class Translations$shareme$time$en {
  Translations$shareme$time$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'just now'
  String get justNow => 'just now';

  /// en: '{n} min ago'
  String minutesAgo({required Object n}) => '${n} min ago';

  /// en: '{n} h ago'
  String hoursAgo({required Object n}) => '${n} h ago';

  /// en: '{n} d ago'
  String daysAgo({required Object n}) => '${n} d ago';

  /// en: '{n} s'
  String seconds({required Object n}) => '${n} s';

  /// en: '{m} min {s} s'
  String minSec({required Object m, required Object s}) => '${m} min ${s} s';
}

// Path: shareme.home
class Translations$shareme$home$en {
  Translations$shareme$home$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Scan to pair'
  String get scanToPair => 'Scan to pair';

  /// en: 'Nearby devices can find you'
  String get meVisible => 'Nearby devices can find you';

  /// en: 'Receiving is off. Nearby devices can't find you'
  String get meHidden => 'Receiving is off. Nearby devices can\'t find you';

  /// en: 'Just received'
  String get justReceived => 'Just received';

  /// en: 'All history'
  String get allHistory => 'All history';

  /// en: '{from}→this device'
  String edgeFrom({required Object from}) => '${from}→this device';

  /// en: 'original quality'
  String get edgeOriginal => 'original quality';

  /// en: 'verified'
  String get edgeVerified => 'verified';

  /// en: 'My devices'
  String get myDevices => 'My devices';

  /// en: 'Nearby'
  String get nearby => 'Nearby';

  /// en: 'not paired, needs approval'
  String get nearbyNote => 'not paired, needs approval';

  /// en: 'No devices found nearby yet. Make sure both devices are on the same Wi-Fi, then select Refresh next to Nearby.'
  String get noNearby => 'No devices found nearby yet. Make sure both devices are on the same Wi-Fi, then select Refresh next to Nearby.';

  /// en: 'Refresh'
  String get refresh => 'Refresh';

  /// en: 'Drop files here to send'
  String get dropTitle => 'Drop files here to send';

  /// en: 'or press Ctrl+V to send the clipboard'
  String get dropHint => 'or press Ctrl+V to send the clipboard';

  /// en: 'or press ⌘V to send the clipboard'
  String get dropHintMac => 'or press ⌘V to send the clipboard';

  /// en: 'Release, then choose who to send to'
  String get dropActive => 'Release, then choose who to send to';

  /// en: 'Files'
  String get pickFiles => 'Files';

  /// en: 'Folder'
  String get pickFolder => 'Folder';

  /// en: 'Text'
  String get sendTextOrLink => 'Text';

  /// en: 'Recent'
  String get recent => 'Recent';

  /// en: 'No devices in My devices yet'
  String get emptyTitle => 'No devices in My devices yet';

  /// en: 'Pair once, then just send'
  String get emptyBody => 'Pair once, then just send';

  /// en: 'Online'
  String get sameWifi => 'Online';

  /// en: 'Online · remote'
  String get viaTailscale => 'Online · remote';

  /// en: 'Online · remote'
  String get crossNetwork => 'Online · remote';

  /// en: 'Offline'
  String get offline => 'Offline';

  /// en: '{name} is offline'
  String offlineTap({required Object name}) => '${name} is offline';

  /// en: '{n} more offline'
  String offlineMore({required Object n}) => '${n} more offline';

  /// en: 'Add'
  String get add => 'Add';

  /// en: 'Add device'
  String get addDevice => 'Add device';

  /// en: 'Original'
  String get original => 'Original';

  /// en: 'From {name}'
  String fromName({required Object name}) => 'From ${name}';

  /// en: 'Add to My devices'
  String get addToMine => 'Add to My devices';

  /// en: 'Remove from My devices'
  String get removeFromMine => 'Remove from My devices';

  /// en: 'Not verified'
  String get unverified => 'Not verified';

  /// en: 'Verify this device'
  String get verifyDevice => 'Verify this device';

  /// en: '{time} left'
  String remaining({required Object time}) => '${time} left';

  /// en: '{n} selected · {size}'
  String selected({required Object n, required Object size}) => '${n} selected · ${size}';

  /// en: 'Tap a device to send'
  String get selectedHint => 'Tap a device to send';

  /// en: 'Clear'
  String get clear => 'Clear';

  /// en: 'Photos & videos'
  String get sendMedia => 'Photos & videos';

  /// en: 'Send to'
  String get sendTo => 'Send to';

  /// en: 'Drop here to send to {name}'
  String dropTitleTo({required Object name}) => 'Drop here to send to ${name}';

  /// en: 'Send to {name}'
  String sendToName({required Object name}) => 'Send to ${name}';

  /// en: 'Release to send to {name}'
  String dropActiveTo({required Object name}) => 'Release to send to ${name}';

  /// en: 'Files'
  String get file => 'Files';

  /// en: 'Text'
  String get text => 'Text';

  /// en: '(one) {1 item} (other) {{n} items}'
  String edgeCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 item',
    other: '${n} items',
  );

  /// en: '(one) {Sending 1 item} (other) {Sending {n} items}'
  String sending({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Sending 1 item',
    other: 'Sending ${n} items',
  );

  /// en: '(one) {Waiting · 1 item} (other) {Waiting · {n} items}'
  String waiting({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Waiting · 1 item',
    other: 'Waiting · ${n} items',
  );
}

// Path: shareme.safety
class Translations$shareme$safety$en {
  Translations$shareme$safety$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'This file can run a program'
  String get runnableTitle => 'This file can run a program';

  /// en: 'To keep you safe, Shuttle doesn't open it directly. If it's yours, open it from its folder.'
  String get runnableBody => 'To keep you safe, Shuttle doesn\'t open it directly. If it\'s yours, open it from its folder.';

  /// en: 'Show in folder'
  String get showInFolder => 'Show in folder';
}

// Path: shareme.send
class Translations$shareme$send$en {
  Translations$shareme$send$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send to'
  String get sheetTitle => 'Send to';

  /// en: 'Stop sending?'
  String get stopTitle => 'Stop sending?';

  /// en: 'Stop'
  String get stop => 'Stop';

  /// en: 'Keep going'
  String get keepGoing => 'Keep going';

  /// en: 'No Shuttle there? Share a link'
  String get shareLink => 'No Shuttle there? Share a link';

  /// en: 'Offline · can send once it's online'
  String get offlineCannot => 'Offline · can send once it\'s online';

  /// en: 'Needs approval'
  String get nearbyNeedsApproval => 'Needs approval';

  /// en: 'No devices found nearby yet. Make sure both devices are on the same Wi-Fi.'
  String get noDevices => 'No devices found nearby yet. Make sure both devices are on the same Wi-Fi.';

  /// en: 'Send to {name}'
  String sendTo({required Object name}) => 'Send to ${name}';

  /// en: 'Choose a device first'
  String get chooseDevice => 'Choose a device first';

  /// en: 'Waiting for {name} to accept'
  String waitingTitle({required Object name}) => 'Waiting for ${name} to accept';

  /// en: 'Tap Accept on {name}. It starts automatically if {name} accepts files automatically.'
  String waitingBody({required Object name}) => 'Tap Accept on ${name}. It starts automatically if ${name} accepts files automatically.';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Sending to'
  String get sendingTo => 'Sending to';

  /// en: 'item {i} / {n}'
  String fileIndex({required Object i, required Object n}) => 'item ${i} / ${n}';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'encrypted'
  String get encrypted => 'encrypted';

  /// en: 'not encrypted'
  String get notEncrypted => 'not encrypted';

  /// en: 'Leaving this page won't stop the transfer. Progress is shown in the notification.'
  String get leaveHint => 'Leaving this page won\'t stop the transfer. Progress is shown in the notification.';

  /// en: 'Cancel sending'
  String get cancelSend => 'Cancel sending';

  /// en: 'waiting'
  String get queued => 'waiting';

  /// en: 'failed'
  String get failed => 'failed';

  /// en: 'Done'
  String get done => 'Done';

  /// en: 'Send more'
  String get sendMore => 'Send more';

  /// en: 'Delivered to'
  String get deliveredTo => 'Delivered to';

  /// en: 'Delivered'
  String get delivered => 'Delivered';

  /// en: 'size'
  String get statSize => 'size';

  /// en: 'time'
  String get statTime => 'time';

  /// en: 'avg speed'
  String get statSpeed => 'avg speed';

  /// en: 'Originals'
  String get originalTitle => 'Originals';

  /// en: 'The original files were sent without compression, each with its SHA-256 so the receiver can verify it.'
  String get originalWithHash => 'The original files were sent without compression, each with its SHA-256 so the receiver can verify it.';

  /// en: 'The original files were sent without compression.'
  String get originalNoHash => 'The original files were sent without compression.';

  /// en: 'original'
  String get originalBadge => 'original';

  /// en: 'Resend'
  String get retry => 'Resend';

  /// en: '{name} declined the transfer'
  String declined({required Object name}) => '${name} declined the transfer';

  /// en: '{name} is receiving other files. Try again later'
  String busy({required Object name}) => '${name} is receiving other files. Try again later';

  /// en: 'Too many wrong PIN attempts. Try again later'
  String get tooMany => 'Too many wrong PIN attempts. Try again later';

  /// en: '{name} canceled the transfer'
  String canceledByReceiver({required Object name}) => '${name} canceled the transfer';

  /// en: 'Sending canceled'
  String get canceledBySender => 'Sending canceled';

  /// en: 'Couldn't send to {name}'
  String notSent({required Object name}) => 'Couldn\'t send to ${name}';

  /// en: 'Not sent, for your safety: it isn't using an encrypted connection, so someone on this Wi-Fi may be impersonating it.'
  String get insecure => 'Not sent, for your safety: it isn\'t using an encrypted connection, so someone on this Wi-Fi may be impersonating it.';

  /// en: '{name} couldn't be reached. Check that Shuttle is open there; when you're not on the same Wi-Fi, both devices need Tailscale on.'
  String notSentHint({required Object name}) =>
      '${name} couldn\'t be reached. Check that Shuttle is open there; when you\'re not on the same Wi-Fi, both devices need Tailscale on.';

  /// en: 'It may be asleep, or Shuttle isn't open.'
  String get notSentReason => 'It may be asleep, or Shuttle isn\'t open.';

  /// en: 'When you're not on the same Wi-Fi, both devices need Tailscale on.'
  String get notSentReasonRemote => 'When you\'re not on the same Wi-Fi, both devices need Tailscale on.';

  /// en: 'Details'
  String get details => 'Details';

  /// en: 'Going back in 2 seconds'
  String get autoBack => 'Going back in 2 seconds';

  /// en: 'Retrying automatically (attempt {n})'
  String autoRetrying({required Object n}) => 'Retrying automatically (attempt ${n})';

  /// en: 'Connecting…'
  String get connecting => 'Connecting…';

  /// en: 'Preparing {curr}/{n}'
  String preparing({required Object curr, required Object n}) => 'Preparing ${curr}/${n}';

  /// en: 'Retry'
  String get retryAll => 'Retry';

  /// en: 'Back'
  String get back => 'Back';

  /// en: '(one) {1 item · {size}} (other) {{n} items · {size}}'
  String sheetSummary({required num n, required Object size}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 item · ${size}',
    other: '${n} items · ${size}',
  );

  /// en: '(one) {1 item. The receiver got the original.} (other) {{n} items. The receiver got the originals.}'
  String deliveredBody({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 item. The receiver got the original.',
    other: '${n} items. The receiver got the originals.',
  );

  /// en: '(one) {1 file was not sent} (other) {{n} files were not sent}'
  String failedTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 file was not sent',
    other: '${n} files were not sent',
  );
}

// Path: shareme.text
class Translations$shareme$text$en {
  Translations$shareme$text$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send text or a link'
  String get sheetTitle => 'Send text or a link';

  /// en: 'Send clipboard to my device'
  String get clipTray => 'Send clipboard to my device';

  /// en: 'The clipboard is empty'
  String get clipEmpty => 'The clipboard is empty';

  /// en: 'Copied, from {name}'
  String snackCopied({required Object name}) => 'Copied, from ${name}';

  /// en: 'Link from {name}'
  String snackLink({required Object name}) => 'Link from ${name}';

  /// en: 'View'
  String get snackView => 'View';

  /// en: 'Open'
  String get snackOpen => 'Open';

  /// en: 'From My devices, copied automatically'
  String get autoCopied => 'From My devices, copied automatically';

  /// en: 'There is a link on your clipboard'
  String get clipboardLink => 'There is a link on your clipboard';

  /// en: 'There is text on your clipboard'
  String get clipboardText => 'There is text on your clipboard';

  /// en: 'Paste'
  String get paste => 'Paste';

  /// en: 'Type the text or link to send'
  String get hint => 'Type the text or link to send';

  /// en: 'Send to'
  String get sendTo => 'Send to';

  /// en: 'Send'
  String get send => 'Send';

  /// en: 'sent you a link'
  String get receivedLink => 'sent you a link';

  /// en: 'sent you some text'
  String get receivedText => 'sent you some text';

  /// en: 'Shuttle won't open this address in the background or fetch its title and images (that would reveal your IP to the website).'
  String get linkNote =>
      'Shuttle won\'t open this address in the background or fetch its title and images (that would reveal your IP to the website).';

  /// en: 'Copy'
  String get copy => 'Copy';

  /// en: 'Copied'
  String get copied => 'Copied';

  /// en: 'Open link'
  String get openLink => 'Open link';

  /// en: 'Close'
  String get close => 'Close';

  /// en: 'Saved to history'
  String get savedToHistory => 'Saved to history';

  /// en: 'Only the beginning is shown, Copy takes everything'
  String get excerpt => 'Only the beginning is shown, Copy takes everything';

  /// en: 'Sent to {name}'
  String sentTo({required Object name}) => 'Sent to ${name}';

  /// en: '(one) {1 char} (other) {{n} chars}'
  String count({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 char',
    other: '${n} chars',
  );
}

// Path: shareme.receive
class Translations$shareme$receive$en {
  Translations$shareme$receive$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'My device · certificate fingerprint matches'
  String get mineVerified => 'My device · certificate fingerprint matches';

  /// en: 'My device · not encrypted, identity can't be confirmed'
  String get mineUnencrypted => 'My device · not encrypted, identity can\'t be confirmed';

  /// en: 'My device · not verified, so you're asked each time'
  String get mineUnchecked => 'My device · not verified, so you\'re asked each time';

  /// en: 'Accept automatically from verified devices'
  String get autoAcceptVerified => 'Accept automatically from verified devices';

  /// en: 'Device fingerprint'
  String get fingerprint => 'Device fingerprint';

  /// en: 'Unknown device'
  String get stranger => 'Unknown device';

  /// en: 'Stop receiving?'
  String get stopTitle => 'Stop receiving?';

  /// en: 'Not encrypted'
  String get notEncrypted => 'Not encrypted';

  /// en: 'Decide later (Esc)'
  String get later => 'Decide later (Esc)';

  /// en: 'This device is not in My devices.'
  String get strangerTitle => 'This device is not in My devices.';

  /// en: 'Only accept if you know this device.'
  String get strangerBody => 'Only accept if you know this device.';

  /// en: 'This connection is not encrypted. People on the same Wi-Fi may be able to see the content.'
  String get unencrypted => 'This connection is not encrypted. People on the same Wi-Fi may be able to see the content.';

  /// en: 'Contents'
  String get contents => 'Contents';

  /// en: 'original quality'
  String get original => 'original quality';

  /// en: 'Accept automatically from My devices'
  String get autoAccept => 'Accept automatically from My devices';

  /// en: 'Decline'
  String get decline => 'Decline';

  /// en: 'Accept'
  String get accept => 'Accept';

  /// en: 'The sender canceled'
  String get canceledBySender => 'The sender canceled';

  /// en: 'Close'
  String get close => 'Close';

  /// en: 'Getting ready to receive…'
  String get preparing => 'Getting ready to receive…';

  /// en: 'Receiving from'
  String get receivingFrom => 'Receiving from';

  /// en: '{n} received'
  String receivedShort({required Object n}) => '${n} received';

  /// en: 'from {name} · took {time} · avg {speed}'
  String receivedFrom({required Object name, required Object time, required Object speed}) => 'from ${name} · took ${time} · avg ${speed}';

  /// en: 'Where they were saved'
  String get whereSaved => 'Where they were saved';

  /// en: 'Saved to gallery'
  String get savedToGallery => 'Saved to gallery';

  /// en: 'Open'
  String get open => 'Open';

  /// en: 'View in gallery'
  String get viewInGallery => 'View in gallery';

  /// en: 'Open folder'
  String get openFolder => 'Open folder';

  /// en: 'Cancel receiving'
  String get cancelReceive => 'Cancel receiving';

  /// en: 'Accept from this device automatically from now on'
  String get popupRemember => 'Accept from this device automatically from now on';

  /// en: 'Not in My devices. Only accept if you know this device.'
  String get popupStranger => 'Not in My devices. Only accept if you know this device.';

  /// en: 'Press Esc to decide later'
  String get popupEsc => 'Press Esc to decide later';

  /// en: 'item {i} of {n}'
  String popupFileOf({required Object i, required Object n}) => 'item ${i} of ${n}';

  /// en: 'Receiving'
  String get popupReceiving => 'Receiving';

  /// en: '{time} left'
  String popupLeft({required Object time}) => '${time} left';

  /// en: 'Saved to {path}'
  String popupSavedTo({required Object path}) => 'Saved to ${path}';

  /// en: '(one) {wants to send you 1 item, {size} in total} (other) {wants to send you {n} items, {size} in total}'
  String wantsToSend({required num n, required Object size}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'wants to send you 1 item, ${size} in total',
    other: 'wants to send you ${n} items, ${size} in total',
  );

  /// en: '(one) {1 photo} (other) {{n} photos}'
  String photos({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 photo',
    other: '${n} photos',
  );

  /// en: '(one) {1 video} (other) {{n} videos}'
  String videos({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 video',
    other: '${n} videos',
  );

  /// en: '(one) {1 file} (other) {{n} files}'
  String files({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 file',
    other: '${n} files',
  );

  /// en: '(one) {Received 1 item} (other) {Received {n} items}'
  String receivedTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Received 1 item',
    other: 'Received ${n} items',
  );

  /// en: '(one) {Photos & videos · 1 item} (other) {Photos & videos · {n} items}'
  String mediaItems({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Photos & videos · 1 item',
    other: 'Photos & videos · ${n} items',
  );

  /// en: '(one) {1 file was not received} (other) {{n} files were not received}'
  String failedTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 file was not received',
    other: '${n} files were not received',
  );

  /// en: '(one) {Received 1 item from {name}} (other) {Received {n} items from {name}}'
  String quickSaved({required num n, required Object name}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Received 1 item from ${name}',
    other: 'Received ${n} items from ${name}',
  );
}

// Path: shareme.history
class Translations$shareme$history$en {
  Translations$shareme$history$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'History'
  String get title => 'History';

  /// en: 'All'
  String get all => 'All';

  /// en: 'Photos & videos'
  String get media => 'Photos & videos';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'Text & links'
  String get texts => 'Text & links';

  /// en: 'Today'
  String get today => 'Today';

  /// en: 'Yesterday'
  String get yesterday => 'Yesterday';

  /// en: 'From'
  String get from => 'From';

  /// en: 'To'
  String get to => 'To';

  /// en: ' (not paired)'
  String get unpaired => ' (not paired)';

  /// en: 'Not sent: {reason}'
  String sendFailed({required Object reason}) => 'Not sent: ${reason}';

  /// en: 'declined'
  String get reasonDeclined => 'declined';

  /// en: 'canceled by receiver'
  String get reasonCanceledByReceiver => 'canceled by receiver';

  /// en: 'you canceled'
  String get reasonCanceledBySender => 'you canceled';

  /// en: 'receiver busy'
  String get reasonBusy => 'receiver busy';

  /// en: 'too many wrong PINs'
  String get reasonPin => 'too many wrong PINs';

  /// en: 'error'
  String get reasonError => 'error';

  /// en: 'Nothing sent or received yet'
  String get emptyTitle => 'Nothing sent or received yet';

  /// en: 'Everything you receive and send shows up here.'
  String get emptyBody => 'Everything you receive and send shows up here.';

  /// en: 'Send photos & videos'
  String get emptyAction => 'Send photos & videos';

  /// en: 'Send files'
  String get emptyActionFiles => 'Send files';

  /// en: 'Nothing in this category yet.'
  String get emptyFilter => 'Nothing in this category yet.';

  /// en: 'Search'
  String get search => 'Search';

  /// en: 'Search files, text or devices'
  String get searchHint => 'Search files, text or devices';

  /// en: 'Nothing found'
  String get searchEmpty => 'Nothing found';

  /// en: 'History is off, so new transfers are not recorded. Turn on "Save to history" in settings.'
  String get off => 'History is off, so new transfers are not recorded. Turn on "Save to history" in settings.';

  /// en: 'Clear history'
  String get clearAll => 'Clear history';

  /// en: 'Clear all history?'
  String get clearAllTitle => 'Clear all history?';

  /// en: 'Only the records are removed. Received files stay.'
  String get clearAllBody => 'Only the records are removed. Received files stay.';

  /// en: 'Delete this record?'
  String get deleteTitle => 'Delete this record?';

  /// en: 'Only the record is removed. The files stay.'
  String get deleteBody => 'Only the record is removed. The files stay.';

  /// en: 'Delete'
  String get delete => 'Delete';

  /// en: 'Delete this record'
  String get deleteRecord => 'Delete this record';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'From {name} · {time}'
  String fromAt({required Object name, required Object time}) => 'From ${name} · ${time}';

  /// en: 'To {name} · {time}'
  String toAt({required Object name, required Object time}) => 'To ${name} · ${time}';

  /// en: 'Link sent to {name}'
  String sentLink({required Object name}) => 'Link sent to ${name}';

  /// en: 'Text sent to {name}'
  String sentText({required Object name}) => 'Text sent to ${name}';

  /// en: 'Link from {name}'
  String receivedLink({required Object name}) => 'Link from ${name}';

  /// en: 'Text from {name}'
  String receivedText({required Object name}) => 'Text from ${name}';

  /// en: 'not sent'
  String get notDelivered => 'not sent';

  /// en: 'To {name}'
  String edgeTo({required Object name}) => 'To ${name}';

  /// en: '(one) {1 photo or video} (other) {{n} photos & videos}'
  String mediaCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 photo or video',
    other: '${n} photos & videos',
  );

  /// en: '(one) {1 photo} (other) {{n} photos}'
  String photoCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 photo',
    other: '${n} photos',
  );

  /// en: '(one) {1 video} (other) {{n} videos}'
  String videoCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 video',
    other: '${n} videos',
  );

  /// en: '(one) {1 file} (other) {{n} files}'
  String fileCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 file',
    other: '${n} files',
  );

  /// en: '(one) {1 item} (other) {{n} items}'
  String itemCount({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 item',
    other: '${n} items',
  );

  /// en: '(one) {1 item not sent} (other) {{n} items not sent}'
  String partFailed({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: '1 item not sent',
    other: '${n} items not sent',
  );

  /// en: '(one) {Sent 1 item} (other) {Sent {n} items}'
  String sentTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Sent 1 item',
    other: 'Sent ${n} items',
  );
}

// Path: shareme.pair
class Translations$shareme$pair$en {
  Translations$shareme$pair$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Pair a new device'
  String get hostTitle => 'Pair a new device';

  /// en: 'Scan it with Shuttle on your phone'
  String get scanMe => 'Scan it with Shuttle on your phone';

  /// en: 'Another computer?'
  String get otherPc => 'Another computer?';

  /// en: 'On your phone, open Shuttle, tap the scan button at the top right of the home screen, and point it at this code.'
  String get pairHostHint => 'On your phone, open Shuttle, tap the scan button at the top right of the home screen, and point it at this code.';

  /// en: 'The code works once, for 5 minutes, and doesn't contain this computer's name.'
  String get hostOneUse => 'The code works once, for 5 minutes, and doesn\'t contain this computer\'s name.';

  /// en: 'Expires in {time}'
  String expiresIn({required Object time}) => 'Expires in ${time}';

  /// en: 'This code has expired'
  String get expired => 'This code has expired';

  /// en: 'New code'
  String get newCode => 'New code';

  /// en: 'This computer isn't on a local network, so your phone can't reach it. Connect to Wi-Fi or Ethernet first.'
  String get noNetwork => 'This computer isn\'t on a local network, so your phone can\'t reach it. Connect to Wi-Fi or Ethernet first.';

  /// en: 'Couldn't start pairing: {error}'
  String startFailed({required Object error}) => 'Couldn\'t start pairing: ${error}';

  /// en: 'Waiting for the phone to confirm…'
  String get waitPhone => 'Waiting for the phone to confirm…';

  /// en: 'Waiting for the computer to confirm…'
  String get waitComputer => 'Waiting for the computer to confirm…';

  /// en: 'Name it'
  String get nameIt => 'Name it';

  /// en: 'Another device scanned this code. If the device you're checking isn't your phone, select Cancel.'
  String get intruder => 'Another device scanned this code. If the device you\'re checking isn\'t your phone, select Cancel.';

  /// en: 'Paired'
  String get doneTitle => 'Paired';

  /// en: 'Files from {name} are accepted from now on'
  String doneAuto({required Object name}) => 'Files from ${name} are accepted from now on';

  /// en: 'Files from {name} will ask you first'
  String doneAsk({required Object name}) => 'Files from ${name} will ask you first';

  /// en: 'Done'
  String get done => 'Done';

  /// en: 'Scan again'
  String get tryAgain => 'Scan again';

  /// en: 'Canceled. Not paired.'
  String get failRejectedHere => 'Canceled. Not paired.';

  /// en: 'The other device canceled. Not paired.'
  String get failRejectedPeer => 'The other device canceled. Not paired.';

  /// en: 'This code was already used by another device. If that wasn't you, remove the unknown device on the computer, then scan a new code.'
  String get failUsed =>
      'This code was already used by another device. If that wasn\'t you, remove the unknown device on the computer, then scan a new code.';

  /// en: 'The code expired. Make a new one on the computer and scan again.'
  String get failExpired => 'The code expired. Make a new one on the computer and scan again.';

  /// en: 'Can't reach the computer. Make sure both devices are on the same Wi-Fi and the pairing page is still open on the computer.'
  String get failUnreachable =>
      'Can\'t reach the computer. Make sure both devices are on the same Wi-Fi and the pairing page is still open on the computer.';

  /// en: 'The computer's identity check failed, so pairing stopped. Someone may be impersonating it.'
  String get failIdentity => 'The computer\'s identity check failed, so pairing stopped. Someone may be impersonating it.';

  /// en: 'Nobody confirmed in time. Not paired.'
  String get failTimeout => 'Nobody confirmed in time. Not paired.';

  /// en: 'Pairing didn't finish (the messages didn't match). Please try again.'
  String get failProtocol => 'Pairing didn\'t finish (the messages didn\'t match). Please try again.';

  /// en: 'Scan to pair'
  String get scanTitle => 'Scan to pair';

  /// en: 'Scan the code on your computer'
  String get scanFrame => 'Scan the code on your computer';

  /// en: 'How to show the code on your computer'
  String get scanHowTitle => 'How to show the code on your computer';

  /// en: 'On the computer, open Shuttle and click Add device'
  String get scanHowBody => 'On the computer, open Shuttle and click Add device';

  /// en: 'That's not a Shuttle pairing code'
  String get notOurCode => 'That\'s not a Shuttle pairing code';

  /// en: 'Connecting to the computer…'
  String get connecting => 'Connecting to the computer…';

  /// en: 'Can't open the camera: {error}'
  String cameraError({required Object error}) => 'Can\'t open the camera: ${error}';

  /// en: 'Verified'
  String get verified => 'Verified';

  /// en: 'Another computer: under Nearby on its home screen, click Pair next to this computer.'
  String get nearbyHostHint => 'Another computer: under Nearby on its home screen, click Pair next to this computer.';

  /// en: 'Pair'
  String get nearbyButton => 'Pair';

  /// en: 'Pair with {name}'
  String nearbyTitle({required Object name}) => 'Pair with ${name}';

  /// en: 'Connecting to {name}…'
  String nearbyConnecting({required Object name}) => 'Connecting to ${name}…';

  /// en: 'On {name}, open Shuttle and click Pair next to this computer under Nearby (or click Add device). This continues on its own as soon as you do.'
  String nearbyOpenOther({required Object name}) =>
      'On ${name}, open Shuttle and click Pair next to this computer under Nearby (or click Add device). This continues on its own as soon as you do.';

  /// en: 'Not Shuttle on the other side? Add without checking'
  String get nearbyAddPlain => 'Not Shuttle on the other side? Add without checking';

  /// en: 'Try again'
  String get tryAgainShort => 'Try again';

  /// en: '{name} is pairing with another device. Try again in a moment.'
  String failNearbyBusy({required Object name}) => '${name} is pairing with another device. Try again in a moment.';

  /// en: 'Can't reach {name}. On it, click Pair next to this computer (or open Add device), and make sure both computers are on the same network.'
  String failNearbyUnreachable({required Object name}) =>
      'Can\'t reach ${name}. On it, click Pair next to this computer (or open Add device), and make sure both computers are on the same network.';

  /// en: 'The pairing page on {name} timed out. Open Add device on {name} again, then click Try again.'
  String failNearbyExpired({required Object name}) =>
      'The pairing page on ${name} timed out. Open Add device on ${name} again, then click Try again.';

  /// en: '{name} wants to pair with this computer'
  String requestTitle({required Object name}) => '${name} wants to pair with this computer';

  /// en: 'Accept only if you just clicked Pair on {name}. If you don't recognise it, select Ignore. Phones can still scan the code below.'
  String requestHint({required Object name}) =>
      'Accept only if you just clicked Pair on ${name}. If you don\'t recognise it, select Ignore. Phones can still scan the code below.';

  /// en: 'Accept'
  String get requestAccept => 'Accept';

  /// en: 'Ignore'
  String get requestIgnore => 'Ignore';

  /// en: 'Pairing request sent. On {name}, select Accept.'
  String nearbyWaitAccept({required Object name}) => 'Pairing request sent. On ${name}, select Accept.';

  /// en: '{name} ignored the request. Not paired.'
  String failNearbyDeclined({required Object name}) => '${name} ignored the request. Not paired.';

  /// en: 'The other device didn't accept. Not paired.'
  String get failDeclined => 'The other device didn\'t accept. Not paired.';

  /// en: 'A phone scanned this code, but this computer is checking with {name}. If you meant to pair that phone, select Cancel, then show it a new code.'
  String intruderNearby({required Object name}) =>
      'A phone scanned this code, but this computer is checking with ${name}. If you meant to pair that phone, select Cancel, then show it a new code.';

  /// en: 'Finishing pairing…'
  String get finishing => 'Finishing pairing…';

  /// en: 'The computer runs an older Shuttle: check these 12 digits on it, and if they match, select "Same, pair" there.'
  String get legacyHost => 'The computer runs an older Shuttle: check these 12 digits on it, and if they match, select "Same, pair" there.';

  /// en: 'The phone runs an older Shuttle: check these 12 digits on it, and if they match, tap "Same, pair" there.'
  String get legacyGuest => 'The phone runs an older Shuttle: check these 12 digits on it, and if they match, tap "Same, pair" there.';

  /// en: 'Not your device? Remove it'
  String get notMine => 'Not your device? Remove it';

  /// en: 'Another device tried to use this code and was turned away. If {name} isn't yours, select "Not your device? Remove it" below.'
  String intruderAfter({required Object name}) =>
      'Another device tried to use this code and was turned away. If ${name} isn\'t yours, select "Not your device? Remove it" below.';

  /// en: 'Type this on {name}'
  String typedShow({required Object name}) => 'Type this on ${name}';

  /// en: 'Type the code shown on {name}'
  String typedEnter({required Object name}) => 'Type the code shown on ${name}';

  /// en: 'Typing both codes proves neither side is an impostor'
  String get typedHint => 'Typing both codes proves neither side is an impostor';

  /// en: 'That's not it. Check the screen of {name} again (tries left: {n}).'
  String typedWrong({required Object name, required Object n}) => 'That\'s not it. Check the screen of ${name} again (tries left: ${n}).';

  /// en: 'This side checks out. It finishes once you type the code on {name} too.'
  String typedChecked({required Object name}) => 'This side checks out. It finishes once you type the code on ${name} too.';

  /// en: 'The other device runs an older Shuttle. Update it first, then pair.'
  String get failOutdated => 'The other device runs an older Shuttle. Update it first, then pair.';

  /// en: '{name} runs an older Shuttle. Update it first, then pair.'
  String failNearbyOutdated({required Object name}) => '${name} runs an older Shuttle. Update it first, then pair.';

  /// en: '{n} wrong codes, so pairing was canceled. If you typed them right, another device may be impersonating it. Don't pair on this network for now.'
  String failCodeMismatch({required Object n}) =>
      '${n} wrong codes, so pairing was canceled. If you typed them right, another device may be impersonating it. Don\'t pair on this network for now.';
}

// Path: shareme.settings
class Translations$shareme$settings$en {
  Translations$shareme$settings$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Settings'
  String get title => 'Settings';

  /// en: 'Fingerprint {fp}'
  String fingerprint({required Object fp}) => 'Fingerprint ${fp}';

  /// en: 'Rename'
  String get rename => 'Rename';

  /// en: 'The name nearby devices see'
  String get renameHint => 'The name nearby devices see';

  /// en: 'Save'
  String get save => 'Save';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Receive'
  String get receive => 'Receive';

  /// en: 'When files arrive'
  String get whenReceiving => 'When files arrive';

  /// en: 'Accept from my devices, ask for others'
  String get modeFavorites => 'Accept from my devices, ask for others';

  /// en: 'Always ask me'
  String get modeAsk => 'Always ask me';

  /// en: 'My devices: automatic'
  String get modeFavoritesShort => 'My devices: automatic';

  /// en: 'Accept from verified devices, ask for others'
  String get modeVerified => 'Accept from verified devices, ask for others';

  /// en: 'Verified: automatic'
  String get modeVerifiedShort => 'Verified: automatic';

  /// en: 'Verify'
  String get verify => 'Verify';

  /// en: 'Always ask'
  String get modeAskShort => 'Always ask';

  /// en: 'Everyone: automatic'
  String get modeAllShort => 'Everyone: automatic';

  /// en: 'Save to'
  String get saveTo => 'Save to';

  /// en: 'Downloads'
  String get defaultDownloads => 'Downloads';

  /// en: 'Save photos to gallery'
  String get galleryShort => 'Save photos to gallery';

  /// en: 'Keep photo location'
  String get keepLocationShort => 'Keep photo location';

  /// en: 'On'
  String get turnedOn => 'On';

  /// en: 'Turn on'
  String get turnOn => 'Turn on';

  /// en: '{n} left'
  String missing({required Object n}) => '${n} left';

  /// en: 'View'
  String get view => 'View';

  /// en: 'General'
  String get general => 'General';

  /// en: 'Start at sign-in'
  String get autoStart => 'Start at sign-in';

  /// en: 'Waits in the tray after you sign in, ready to receive'
  String get autoStartNote => 'Waits in the tray after you sign in, ready to receive';

  /// en: 'More'
  String get moreShort => 'More';

  /// en: 'Advanced settings'
  String get localsendSettings => 'Advanced settings';

  /// en: 'Port, encryption and more'
  String get localsendSettingsNote => 'Port, encryption and more';

  /// en: 'Keep history'
  String get saveToHistoryShort => 'Keep history';

  /// en: 'Tailscale'
  String get tailscaleRow => 'Tailscale';

  /// en: 'Connected'
  String get tailscaleConnected => 'Connected';

  /// en: 'Not connected'
  String get tailscaleNotConnected => 'Not connected';

  /// en: 'Install Tailscale on both devices with the same account. When they're not on the same Wi-Fi, Shuttle connects through it, encrypted all the way.'
  String get crossNetworkNote =>
      'Install Tailscale on both devices with the same account. When they\'re not on the same Wi-Fi, Shuttle connects through it, encrypted all the way.';

  /// en: 'This device'
  String get thisDevice => 'This device';

  /// en: 'Fingerprint'
  String get fingerprintLabel => 'Fingerprint';

  /// en: 'Xiaomi needs two more settings. Shuttle can't read them, so tap to check.'
  String get backgroundPageNote => 'Xiaomi needs two more settings. Shuttle can\'t read them, so tap to check.';

  /// en: 'Accept from every device'
  String get modeAll => 'Accept from every device';

  /// en: 'Not recommended: anyone on the same Wi-Fi can save files here'
  String get modeAllWarn => 'Not recommended: anyone on the same Wi-Fi can save files here';

  /// en: 'Save location'
  String get saveLocation => 'Save location';

  /// en: 'Reset'
  String get resetLocation => 'Reset';

  /// en: 'Download (default)'
  String get defaultLocation => 'Download (default)';

  /// en: 'Save photos and videos to gallery'
  String get saveToGallery => 'Save photos and videos to gallery';

  /// en: 'When off, photos and videos go to the save location above'
  String get saveToGalleryNote => 'When off, photos and videos go to the save location above';

  /// en: 'Keep photo location'
  String get keepLocation => 'Keep photo location';

  /// en: 'Allowed to read the location stored in photos'
  String get keepLocationOn => 'Allowed to read the location stored in photos';

  /// en: 'Needs the "media location" permission, otherwise Android removes the location from photos'
  String get keepLocationOff => 'Needs the "media location" permission, otherwise Android removes the location from photos';

  /// en: 'Save to history'
  String get saveToHistory => 'Save to history';

  /// en: 'Receive from a browser'
  String get receiveLink => 'Receive from a browser';

  /// en: 'A link for devices without Shuttle'
  String get receiveLinkNote => 'A link for devices without Shuttle';

  /// en: 'Require a PIN to receive'
  String get receivePin => 'Require a PIN to receive';

  /// en: 'Every device must enter it before sending'
  String get receivePinNote => 'Every device must enter it before sending';

  /// en: 'Everything you receive and send is listed in History'
  String get saveToHistoryNote => 'Everything you receive and send is listed in History';

  /// en: 'Background receiving'
  String get background => 'Background receiving';

  /// en: 'Xiaomi needs extra setup'
  String get backgroundNote => 'Xiaomi needs extra setup';

  /// en: 'Notifications'
  String get notifications => 'Notifications';

  /// en: 'Allowed, used for incoming requests and progress'
  String get notificationsOn => 'Allowed, used for incoming requests and progress';

  /// en: 'Not allowed: you won't see requests in the background'
  String get notificationsOff => 'Not allowed: you won\'t see requests in the background';

  /// en: 'No battery optimization'
  String get battery => 'No battery optimization';

  /// en: 'Done'
  String get batteryOn => 'Done';

  /// en: 'Not set: Android may stop Shuttle in the background'
  String get batteryOff => 'Not set: Android may stop Shuttle in the background';

  /// en: 'Allow autostart'
  String get autostart => 'Allow autostart';

  /// en: 'Xiaomi doesn't let apps read this; tap to check'
  String get autostartNote => 'Xiaomi doesn\'t let apps read this; tap to check';

  /// en: 'Battery saver: No restrictions'
  String get powerSaver => 'Battery saver: No restrictions';

  /// en: 'Xiaomi doesn't let apps read this; tap to check'
  String get powerSaverNote => 'Xiaomi doesn\'t let apps read this; tap to check';

  /// en: 'Note: once the app is swiped away or cleaned up by the system, it can't receive. Always-on background receiving is still in development.'
  String get backgroundLimit =>
      'Note: once the app is swiped away or cleaned up by the system, it can\'t receive. Always-on background receiving is still in development.';

  /// en: 'Couldn't open the Xiaomi page, opened App info instead'
  String get openedAppDetails => 'Couldn\'t open the Xiaomi page, opened App info instead';

  /// en: 'My devices'
  String get devices => 'My devices';

  /// en: 'None yet. Pair by QR code, or tap Add or Pair under Nearby on the home page.'
  String get devicesEmpty => 'None yet. Pair by QR code, or tap Add or Pair under Nearby on the home page.';

  /// en: 'Online'
  String get online => 'Online';

  /// en: 'Offline'
  String get offline => 'Offline';

  /// en: 'Pair a new device'
  String get pairNew => 'Pair a new device';

  /// en: 'Scan the QR code on your computer'
  String get pairNewNote => 'Scan the QR code on your computer';

  /// en: 'Scan this computer's QR code with your phone'
  String get pairNewDesktopNote => 'Scan this computer\'s QR code with your phone';

  /// en: 'Scan, or open in a browser'
  String get linkHint => 'Scan, or open in a browser';

  /// en: 'Copy link'
  String get copyLink => 'Copy link';

  /// en: 'Other addresses'
  String get otherAddresses => 'Other addresses';

  /// en: 'Not connected to a network'
  String get noNetwork => 'Not connected to a network';

  /// en: 'Keep window on top'
  String get alwaysOnTop => 'Keep window on top';

  /// en: 'Animations'
  String get animations => 'Animations';

  /// en: 'Close to tray'
  String get minimizeToTray => 'Close to tray';

  /// en: 'Start hidden at sign-in'
  String get launchMinimized => 'Start hidden at sign-in';

  /// en: 'Show in the "Send to" menu'
  String get contextMenu => 'Show in the "Send to" menu';

  /// en: 'Remember window position'
  String get saveWindow => 'Remember window position';

  /// en: 'Check files after receiving'
  String get verifyChecksums => 'Check files after receiving';

  /// en: 'Add checksums when sending'
  String get createChecksums => 'Add checksums when sending';

  /// en: 'Auto-accept when sharing by link'
  String get linkAutoAccept => 'Auto-accept when sharing by link';

  /// en: 'Receiving'
  String get server => 'Receiving';

  /// en: 'On'
  String get serverOn => 'On';

  /// en: 'Off'
  String get serverOff => 'Off';

  /// en: 'Restart receiving to apply the changes'
  String get needRestart => 'Restart receiving to apply the changes';

  /// en: 'Restart'
  String get restart => 'Restart';

  /// en: 'Start'
  String get start => 'Start';

  /// en: 'Stop'
  String get stop => 'Stop';

  /// en: 'Device type'
  String get deviceType => 'Device type';

  /// en: 'Device model'
  String get deviceModel => 'Device model';

  /// en: 'Port'
  String get port => 'Port';

  /// en: 'Networks'
  String get networks => 'Networks';

  /// en: 'All'
  String get networksAll => 'All';

  /// en: 'Some'
  String get networksSome => 'Some';

  /// en: 'Scan timeout (ms)'
  String get scanTimeout => 'Scan timeout (ms)';

  /// en: 'Encryption'
  String get encryption => 'Encryption';

  /// en: 'Turn encryption off?'
  String get encryptionOffTitle => 'Turn encryption off?';

  /// en: 'People on the same Wi-Fi could see what you send.'
  String get encryptionOffBody => 'People on the same Wi-Fi could see what you send.';

  /// en: 'Turn off'
  String get encryptionOffConfirm => 'Turn off';

  /// en: 'Keep it on'
  String get encryptionKeep => 'Keep it on';

  /// en: 'Network'
  String get network => 'Network';

  /// en: 'Enter a number from 1024 to 65535'
  String get portRange => 'Enter a number from 1024 to 65535';

  /// en: 'Enter an address from 224.0.0.0 to 239.255.255.255'
  String get multicastRange => 'Enter an address from 224.0.0.0 to 239.255.255.255';

  /// en: 'Enter a number from 100 to 60000'
  String get timeoutRange => 'Enter a number from 100 to 60000';

  /// en: 'Multicast address'
  String get multicast => 'Multicast address';

  /// en: 'With a custom port or multicast address other devices may not find you (default {port}, {address})'
  String customNetwork({required Object port, required Object address}) =>
      'With a custom port or multicast address other devices may not find you (default ${port}, ${address})';

  /// en: 'Phone'
  String get typeMobile => 'Phone';

  /// en: 'Computer'
  String get typeDesktop => 'Computer';

  /// en: 'Other'
  String get typeOther => 'Other';

  /// en: 'Remove {name}?'
  String removeTitle({required Object name}) => 'Remove ${name}?';

  /// en: 'You'll be asked again before accepting from it.'
  String get removeBody => 'You\'ll be asked again before accepting from it.';

  /// en: 'Remove'
  String get remove => 'Remove';

  /// en: 'Appearance'
  String get appearance => 'Appearance';

  /// en: 'Theme'
  String get theme => 'Theme';

  /// en: 'System'
  String get themeSystem => 'System';

  /// en: 'Light'
  String get themeLight => 'Light';

  /// en: 'Dark'
  String get themeDark => 'Dark';

  /// en: 'Language'
  String get language => 'Language';

  /// en: 'System'
  String get languageSystem => 'System';

  /// en: 'Across networks'
  String get crossNetwork => 'Across networks';

  /// en: 'Transfer on mobile data'
  String get mobileData => 'Transfer on mobile data';

  /// en: 'Install Tailscale on both devices, sign in with the same account, then pair by QR code once. When they're not on the same Wi-Fi, they'll connect through it automatically, encrypted all the way.'
  String get mobileDataNote =>
      'Install Tailscale on both devices, sign in with the same account, then pair by QR code once. When they\'re not on the same Wi-Fi, they\'ll connect through it automatically, encrypted all the way.';

  /// en: 'This device is on Tailscale: {ip}'
  String tailscaleOn({required Object ip}) => 'This device is on Tailscale: ${ip}';

  /// en: 'This device isn't on Tailscale yet'
  String get tailscaleOff => 'This device isn\'t on Tailscale yet';

  /// en: 'About'
  String get about => 'About';

  /// en: 'Version'
  String get version => 'Version';

  /// en: 'Based on LocalSend {base}'
  String basedOn({required Object base}) => 'Based on LocalSend ${base}';

  /// en: 'Open-source licenses'
  String get license => 'Open-source licenses';

  /// en: 'Built on LocalSend (Apache-2.0)'
  String get licenseNote => 'Built on LocalSend (Apache-2.0)';

  /// en: 'More settings'
  String get more => 'More settings';

  /// en: 'Port, encryption, receive PIN and more'
  String get moreNote => 'Port, encryption, receive PIN and more';

  /// en: 'Shuttle · only between your own devices'
  String get footer => 'Shuttle · only between your own devices';
}

// Path: shareme.update
class Translations$shareme$update$en {
  Translations$shareme$update$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'New version {version}'
  String available({required Object version}) => 'New version ${version}';

  /// en: 'Update'
  String get install => 'Update';

  /// en: 'Downloading {percent}%'
  String downloading({required Object percent}) => 'Downloading ${percent}%';

  /// en: 'Updating…'
  String get installing => 'Updating…';

  /// en: 'The new version failed verification and was not installed'
  String get verifyFailed => 'The new version failed verification and was not installed';

  /// en: 'Check for updates'
  String get check => 'Check for updates';

  /// en: 'Checking…'
  String get checking => 'Checking…';

  /// en: 'Up to date'
  String get upToDate => 'Up to date';

  /// en: 'Couldn't check'
  String get checkFailed => 'Couldn\'t check';

  /// en: 'New version available'
  String get found => 'New version available';

  /// en: 'Check automatically'
  String get auto => 'Check automatically';

  /// en: 'A transfer is running. Update when it's done'
  String get busy => 'A transfer is running. Update when it\'s done';

  /// en: 'Couldn't open the installer'
  String get openFailed => 'Couldn\'t open the installer';

  /// en: 'Download failed. Try again later'
  String get downloadFailed => 'Download failed. Try again later';

  /// en: '{version} ({build})'
  String versionBuild({required Object version, required Object build}) => '${version} (${build})';
}

// Path: receiveTab.infoBox
class Translations$receiveTab$infoBox$en {
  Translations$receiveTab$infoBox$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'IP:'
  String get ip => 'IP:';

  /// en: 'Port:'
  String get port => 'Port:';

  /// en: 'Device name:'
  String get alias => 'Device name:';
}

// Path: receiveTab.quickSave
class Translations$receiveTab$quickSave$en {
  Translations$receiveTab$quickSave$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Off'
  String get off => _root.general.off;

  /// en: 'Favorites'
  String get favorites => 'Favorites';

  /// en: 'On'
  String get on => _root.general.on;
}

// Path: sendTab.selection
class Translations$sendTab$selection$en {
  Translations$sendTab$selection$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Selection'
  String get title => 'Selection';

  /// en: 'Files: {files}'
  String files({required Object files}) => 'Files: ${files}';

  /// en: 'Size: {size}'
  String size({required Object size}) => 'Size: ${size}';
}

// Path: sendTab.picker
class Translations$sendTab$picker$en {
  Translations$sendTab$picker$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'File'
  String get file => 'File';

  /// en: 'Folder'
  String get folder => 'Folder';

  /// en: 'Media'
  String get media => 'Media';

  /// en: 'Text'
  String get text => 'Text';

  /// en: 'App'
  String get app => 'App';

  /// en: 'Paste'
  String get clipboard => 'Paste';
}

// Path: sendTab.sendModes
class Translations$sendTab$sendModes$en {
  Translations$sendTab$sendModes$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Single recipient'
  String get single => 'Single recipient';

  /// en: 'Multiple recipients'
  String get multiple => 'Multiple recipients';

  /// en: 'Share via link'
  String get link => 'Share via link';
}

// Path: settingsTab.general
class Translations$settingsTab$general$en {
  Translations$settingsTab$general$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'General'
  String get title => 'General';

  /// en: 'Theme'
  String get brightness => 'Theme';

  late final Translations$settingsTab$general$brightnessOptions$en brightnessOptions = Translations$settingsTab$general$brightnessOptions$en.internal(
    _root,
  );

  /// en: 'Color'
  String get color => 'Color';

  late final Translations$settingsTab$general$colorOptions$en colorOptions = Translations$settingsTab$general$colorOptions$en.internal(_root);

  /// en: 'Language'
  String get language => 'Language';

  late final Translations$settingsTab$general$languageOptions$en languageOptions = Translations$settingsTab$general$languageOptions$en.internal(
    _root,
  );

  /// en: 'Save window position after quit'
  String get saveWindowPlacement => 'Save window position after quit';

  /// en: 'Save window position after exit'
  String get saveWindowPlacementWindows => 'Save window position after exit';

  /// en: 'Always on top'
  String get alwaysOnTop => 'Always on top';

  /// en: 'Not supported on Wayland'
  String get alwaysOnTopUnavailable => 'Not supported on Wayland';

  /// en: 'Minimize to the System Tray/Menu Bar when closing'
  String get minimizeToTray => 'Minimize to the System Tray/Menu Bar when closing';

  /// en: 'Autostart after login'
  String get launchAtStartup => 'Autostart after login';

  /// en: 'Autostart: Start hidden'
  String get launchMinimized => 'Autostart: Start hidden';

  /// en: 'Show Shuttle in context menu'
  String get showInContextMenu => 'Show Shuttle in context menu';

  /// en: 'Animations'
  String get animations => 'Animations';
}

// Path: settingsTab.receive
class Translations$settingsTab$receive$en {
  Translations$settingsTab$receive$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive'
  String get title => 'Receive';

  /// en: 'Quick Save'
  String get quickSave => _root.general.quickSave;

  /// en: 'Quick Save for "Favorites"'
  String get quickSaveFromFavorites => _root.general.quickSaveFromFavorites;

  /// en: 'Require PIN'
  String get requirePin => _root.webSharePage.requirePin;

  /// en: 'Auto Finish'
  String get autoFinish => 'Auto Finish';

  /// en: 'Save to folder'
  String get destination => 'Save to folder';

  /// en: '(Downloads)'
  String get downloads => '(Downloads)';

  /// en: 'Save media to gallery'
  String get saveToGallery => 'Save media to gallery';

  /// en: 'Save to history'
  String get saveToHistory => 'Save to history';

  /// en: 'Verify checksums when receiving files'
  String get verifyChecksums => 'Verify checksums when receiving files';
}

// Path: settingsTab.send
class Translations$settingsTab$send$en {
  Translations$settingsTab$send$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send'
  String get title => 'Send';

  /// en: 'Automatically accept requests in "Share via link" mode'
  String get shareViaLinkAutoAccept => 'Automatically accept requests in "Share via link" mode';

  /// en: 'Create checksums when sending files'
  String get createChecksums => 'Create checksums when sending files';
}

// Path: settingsTab.network
class Translations$settingsTab$network$en {
  Translations$settingsTab$network$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Network'
  String get title => 'Network';

  /// en: 'Restart the server to apply the settings!'
  String get needRestart => 'Restart the server to apply the settings!';

  /// en: 'Server'
  String get server => 'Server';

  /// en: 'Device name'
  String get alias => 'Device name';

  /// en: 'Device type'
  String get deviceType => 'Device type';

  /// en: 'Device model'
  String get deviceModel => 'Device model';

  /// en: 'Port'
  String get port => 'Port';

  /// en: 'Network'
  String get network => 'Network';

  late final Translations$settingsTab$network$networkOptions$en networkOptions = Translations$settingsTab$network$networkOptions$en.internal(_root);

  /// en: 'Discovery Timeout'
  String get discoveryTimeout => 'Discovery Timeout';

  /// en: 'Use system name'
  String get useSystemName => 'Use system name';

  /// en: 'Generate random alias'
  String get generateRandomAlias => 'Generate random alias';

  /// en: 'You might not be detected by other devices because you are using a custom port. (default: {defaultPort})'
  String portWarning({required Object defaultPort}) =>
      'You might not be detected by other devices because you are using a custom port. (default: ${defaultPort})';

  /// en: 'Encryption'
  String get encryption => 'Encryption';

  /// en: 'Multicast address'
  String get multicastGroup => 'Multicast address';

  /// en: 'You might not be detected by other devices because you are using a custom multicast address. (default: {defaultMulticast})'
  String multicastGroupWarning({required Object defaultMulticast}) =>
      'You might not be detected by other devices because you are using a custom multicast address. (default: ${defaultMulticast})';
}

// Path: settingsTab.other
class Translations$settingsTab$other$en {
  Translations$settingsTab$other$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Other'
  String get title => 'Other';

  /// en: 'Support LocalSend (upstream project)'
  String get support => 'Support LocalSend (upstream project)';

  /// en: 'Donate'
  String get donate => 'Donate';

  /// en: 'Privacy Policy'
  String get privacyPolicy => 'Privacy Policy';

  /// en: 'Terms of Use'
  String get termsOfUse => 'Terms of Use';
}

// Path: troubleshootPage.firewall
class Translations$troubleshootPage$firewall$en {
  Translations$troubleshootPage$firewall$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'This device can send files to other devices but other devices cannot send files to this device.'
  String get symptom => 'This device can send files to other devices but other devices cannot send files to this device.';

  /// en: 'This is most likely a firewall issue. You can solve this by allowing incoming connections (UDP and TCP) on port {port}.'
  String solution({required Object port}) =>
      'This is most likely a firewall issue. You can solve this by allowing incoming connections (UDP and TCP) on port ${port}.';

  /// en: 'Open Firewall'
  String get openFirewall => 'Open Firewall';
}

// Path: troubleshootPage.noDiscovery
class Translations$troubleshootPage$noDiscovery$en {
  Translations$troubleshootPage$noDiscovery$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'This device cannot discover other devices.'
  String get symptom => 'This device cannot discover other devices.';

  /// en: 'Please make sure that all devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). You can try to type the IP address of the target device manually. If this works, consider adding this device to the favorites so it can be automatically discovered in the future.'
  String get solution =>
      'Please make sure that all devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). You can try to type the IP address of the target device manually. If this works, consider adding this device to the favorites so it can be automatically discovered in the future.';
}

// Path: troubleshootPage.noConnection
class Translations$troubleshootPage$noConnection$en {
  Translations$troubleshootPage$noConnection$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Both devices cannot discover each other nor can they share files.'
  String get symptom => 'Both devices cannot discover each other nor can they share files.';

  /// en: 'Does the problem exist on both sides? If so, you need to make sure that both devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). The Wi-Fi network may not allow communication between participants due to Access Point (AP) Isolation. In this case, this option must be disabled on the router.'
  String get solution =>
      'Does the problem exist on both sides? If so, you need to make sure that both devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). The Wi-Fi network may not allow communication between participants due to Access Point (AP) Isolation. In this case, this option must be disabled on the router.';
}

// Path: receiveHistoryPage.entryActions
class Translations$receiveHistoryPage$entryActions$en {
  Translations$receiveHistoryPage$entryActions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open file'
  String get open => 'Open file';

  /// en: 'Show in folder'
  String get showInFolder => 'Show in folder';

  /// en: 'Information'
  String get info => 'Information';

  /// en: 'Delete from history'
  String get deleteFromHistory => 'Delete from history';
}

// Path: deviceDetailsPage.info
class Translations$deviceDetailsPage$info$en {
  Translations$deviceDetailsPage$info$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Name'
  String get name => 'Name';

  /// en: 'Address'
  String get address => 'Address';

  /// en: 'Version'
  String get version => 'Version';

  /// en: 'Protocol v{version}'
  String protocol({required Object version}) => 'Protocol v${version}';
}

// Path: deviceDetailsPage.logs
class Translations$deviceDetailsPage$logs$en {
  Translations$deviceDetailsPage$logs$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Logs'
  String get title => 'Logs';

  /// en: 'No logs available.'
  String get empty => 'No logs available.';

  /// en: 'Discovered via {protocol} ({host})'
  String discovered({required Object protocol, required Object host}) => 'Discovered via ${protocol} (${host})';

  /// en: 'Updated via {protocol} ({host})'
  String updated({required Object protocol, required Object host}) => 'Updated via ${protocol} (${host})';
}

// Path: progressPage.total
class Translations$progressPage$total$en {
  Translations$progressPage$total$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$progressPage$total$title$en title = Translations$progressPage$total$title$en.internal(_root);

  /// en: 'Files: {curr} / {n}'
  String count({required Object curr, required Object n}) => 'Files: ${curr} / ${n}';

  /// en: 'Size: {curr} / {n}'
  String size({required Object curr, required Object n}) => 'Size: ${curr} / ${n}';

  /// en: 'Speed: {speed}/s'
  String speed({required Object speed}) => 'Speed: ${speed}/s';
}

// Path: progressPage.remainingTime
class Translations$progressPage$remainingTime$en {
  Translations$progressPage$remainingTime$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: '(other) {{m}m}'
  String minutesUnit({required num m}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    m,
    other: '${m}m',
  );

  /// en: '(other) {{h}h}'
  String hoursUnit({required num h}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    h,
    other: '${h}h',
  );

  /// en: '{m}:{ss}'
  String minutes({required Object m, required Object ss}) => '${m}:${ss}';

  /// en: '(other) {{h}h} (other) {{m}m}'
  String hours({required num h, required num m}) =>
      '${_root.progressPage.remainingTime.hoursUnit(h: h)} ${_root.progressPage.remainingTime.minutesUnit(m: m)}';
}

// Path: whatsNewPage.changes
class Translations$whatsNewPage$changes$en {
  Translations$whatsNewPage$changes$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$whatsNewPage$changes$v1_18_0$en v1_18_0 = Translations$whatsNewPage$changes$v1_18_0$en.internal(_root);
}

// Path: dialogs.addFile
class Translations$dialogs$addFile$en {
  Translations$dialogs$addFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Add to selection'
  String get title => 'Add to selection';

  /// en: 'What do you want to add?'
  String get content => 'What do you want to add?';
}

// Path: dialogs.openFile
class Translations$dialogs$openFile$en {
  Translations$dialogs$openFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open file'
  String get title => 'Open file';

  /// en: 'Do you want to open the received file?'
  String get content => 'Do you want to open the received file?';
}

// Path: dialogs.addressInput
class Translations$dialogs$addressInput$en {
  Translations$dialogs$addressInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter address'
  String get title => 'Enter address';

  /// en: 'Hashtag'
  String get hashtag => 'Hashtag';

  /// en: 'IP Address'
  String get ip => 'IP Address';

  /// en: 'Recently used: '
  String get recentlyUsed => 'Recently used: ';
}

// Path: dialogs.cancelSession
class Translations$dialogs$cancelSession$en {
  Translations$dialogs$cancelSession$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Cancel files transfer'
  String get title => 'Cancel files transfer';

  /// en: 'Do you really want to cancel the files transfer?'
  String get content => 'Do you really want to cancel the files transfer?';
}

// Path: dialogs.cannotOpenFile
class Translations$dialogs$cannotOpenFile$en {
  Translations$dialogs$cannotOpenFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Cannot open file'
  String get title => 'Cannot open file';

  /// en: 'Could not open "{file}". Has this file been moved, renamed or deleted?'
  String content({required Object file}) => 'Could not open "${file}". Has this file been moved, renamed or deleted?';
}

// Path: dialogs.encryptionDisabledNotice
class Translations$dialogs$encryptionDisabledNotice$en {
  Translations$dialogs$encryptionDisabledNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Encryption disabled'
  String get title => 'Encryption disabled';

  /// en: 'Communication now takes place via the unencrypted HTTP protocol. To use HTTPS protocol, enable encryption again.'
  String get content => 'Communication now takes place via the unencrypted HTTP protocol. To use HTTPS protocol, enable encryption again.';
}

// Path: dialogs.errorDialog
class Translations$dialogs$errorDialog$en {
  Translations$dialogs$errorDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Error'
  String get title => _root.general.error;
}

// Path: dialogs.favoriteDialog
class Translations$dialogs$favoriteDialog$en {
  Translations$dialogs$favoriteDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Favorites'
  String get title => 'Favorites';

  /// en: 'No favorite devices yet.'
  String get noFavorites => 'No favorite devices yet.';

  /// en: 'Add'
  String get addFavorite => 'Add';
}

// Path: dialogs.favoriteDeleteDialog
class Translations$dialogs$favoriteDeleteDialog$en {
  Translations$dialogs$favoriteDeleteDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Delete from favorites'
  String get title => 'Delete from favorites';

  /// en: 'Do you really want to delete from favorites "{name}"?'
  String content({required Object name}) => 'Do you really want to delete from favorites "${name}"?';
}

// Path: dialogs.favoriteEditDialog
class Translations$dialogs$favoriteEditDialog$en {
  Translations$dialogs$favoriteEditDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Add to favorites'
  String get titleAdd => 'Add to favorites';

  /// en: 'Settings'
  String get titleEdit => 'Settings';

  /// en: 'Device name'
  String get name => 'Device name';

  /// en: '(auto)'
  String get auto => '(auto)';

  /// en: 'IP Address'
  String get ip => 'IP Address';

  /// en: 'Port'
  String get port => 'Port';

  /// en: 'Enter a whole number between 1 and 65535.'
  String get invalidPort => 'Enter a whole number between 1 and 65535.';
}

// Path: dialogs.fileInfo
class Translations$dialogs$fileInfo$en {
  Translations$dialogs$fileInfo$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'File information'
  String get title => 'File information';

  /// en: 'File name:'
  String get fileName => 'File name:';

  /// en: 'Path:'
  String get path => 'Path:';

  /// en: 'Size:'
  String get size => 'Size:';

  /// en: 'Sender:'
  String get sender => 'Sender:';

  /// en: 'Time:'
  String get time => 'Time:';
}

// Path: dialogs.fileNameInput
class Translations$dialogs$fileNameInput$en {
  Translations$dialogs$fileNameInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter file name'
  String get title => 'Enter file name';

  /// en: 'Original: {original}'
  String original({required Object original}) => 'Original: ${original}';
}

// Path: dialogs.historyClearDialog
class Translations$dialogs$historyClearDialog$en {
  Translations$dialogs$historyClearDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Clear history'
  String get title => 'Clear history';

  /// en: 'Do you really want to delete the entire history?'
  String get content => 'Do you really want to delete the entire history?';
}

// Path: dialogs.localNetworkUnauthorized
class Translations$dialogs$localNetworkUnauthorized$en {
  Translations$dialogs$localNetworkUnauthorized$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No permission'
  String get title => _root.dialogs.noPermission.title;

  /// en: 'Shuttle can't find other devices without having the permission to scan the local network. Please grant this permission in the settings.'
  String get description =>
      'Shuttle can\'t find other devices without having the permission to scan the local network. Please grant this permission in the settings.';

  /// en: 'Settings'
  String get gotoSettings => 'Settings';
}

// Path: dialogs.messageInput
class Translations$dialogs$messageInput$en {
  Translations$dialogs$messageInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Type message'
  String get title => 'Type message';

  /// en: 'Multiline'
  String get multiline => 'Multiline';
}

// Path: dialogs.noFiles
class Translations$dialogs$noFiles$en {
  Translations$dialogs$noFiles$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No files selected'
  String get title => 'No files selected';

  /// en: 'Please select at least one file.'
  String get content => 'Please select at least one file.';
}

// Path: dialogs.noPermission
class Translations$dialogs$noPermission$en {
  Translations$dialogs$noPermission$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No permission'
  String get title => 'No permission';

  /// en: 'You have not granted the necessary permissions. Please grant them in the settings.'
  String get content => 'You have not granted the necessary permissions. Please grant them in the settings.';
}

// Path: dialogs.notAvailableOnPlatform
class Translations$dialogs$notAvailableOnPlatform$en {
  Translations$dialogs$notAvailableOnPlatform$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Not available'
  String get title => 'Not available';

  /// en: 'This feature is only available on:'
  String get content => 'This feature is only available on:';
}

// Path: dialogs.qr
class Translations$dialogs$qr$en {
  Translations$dialogs$qr$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'QR Code'
  String get title => 'QR Code';
}

// Path: dialogs.quickActions
class Translations$dialogs$quickActions$en {
  Translations$dialogs$quickActions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Actions'
  String get title => 'Quick Actions';

  /// en: 'Counter'
  String get counter => 'Counter';

  /// en: 'Prefix'
  String get prefix => 'Prefix';

  /// en: 'Pad with zeros'
  String get padZero => 'Pad with zeros';

  /// en: 'Sort alphabetically beforehand (A-Z)'
  String get sortBeforeCount => 'Sort alphabetically beforehand (A-Z)';

  /// en: 'Random'
  String get random => 'Random';
}

// Path: dialogs.quickSaveNotice
class Translations$dialogs$quickSaveNotice$en {
  Translations$dialogs$quickSaveNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Save'
  String get title => _root.general.quickSave;

  /// en: 'File requests are now accepted automatically. Be aware that everyone on the local network can send you files.'
  String get content => 'File requests are now accepted automatically. Be aware that everyone on the local network can send you files.';
}

// Path: dialogs.quickSaveFromFavoritesNotice
class Translations$dialogs$quickSaveFromFavoritesNotice$en {
  Translations$dialogs$quickSaveFromFavoritesNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Save for "Favorites"'
  String get title => _root.general.quickSaveFromFavorites;

  List<String> get content => [
    'File requests are now accepted automatically from devices in your favorites list.',
  ];
}

// Path: dialogs.pin
class Translations$dialogs$pin$en {
  Translations$dialogs$pin$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter PIN'
  String get title => 'Enter PIN';
}

// Path: dialogs.sendModeHelp
class Translations$dialogs$sendModeHelp$en {
  Translations$dialogs$sendModeHelp$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send modes'
  String get title => 'Send modes';

  /// en: 'Sends files to one recipient. Selection will be cleared after finished files transfer.'
  String get single => 'Sends files to one recipient. Selection will be cleared after finished files transfer.';

  /// en: 'Sends files to multiple recipients. Selection will not be cleared after finished files transfer.'
  String get multiple => 'Sends files to multiple recipients. Selection will not be cleared after finished files transfer.';

  /// en: 'Recipients who do not have Shuttle installed can download the selected files by opening the link in their browser.'
  String get link => 'Recipients who do not have Shuttle installed can download the selected files by opening the link in their browser.';
}

// Path: dialogs.zoom
class Translations$dialogs$zoom$en {
  Translations$dialogs$zoom$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'URL'
  String get title => 'URL';
}

// Path: settingsTab.general.brightnessOptions
class Translations$settingsTab$general$brightnessOptions$en {
  Translations$settingsTab$general$brightnessOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';

  /// en: 'Dark'
  String get dark => 'Dark';

  /// en: 'Light'
  String get light => 'Light';
}

// Path: settingsTab.general.colorOptions
class Translations$settingsTab$general$colorOptions$en {
  Translations$settingsTab$general$colorOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';

  /// en: 'OLED'
  String get oled => 'OLED';

  /// en: 'Custom'
  String get custom => 'Custom';
}

// Path: settingsTab.general.languageOptions
class Translations$settingsTab$general$languageOptions$en {
  Translations$settingsTab$general$languageOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';
}

// Path: settingsTab.network.networkOptions
class Translations$settingsTab$network$networkOptions$en {
  Translations$settingsTab$network$networkOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'All'
  String get all => 'All';

  /// en: 'Filtered'
  String get filtered => 'Filtered';
}

// Path: progressPage.total.title
class Translations$progressPage$total$title$en {
  Translations$progressPage$total$title$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Total progress ({time})'
  String sending({required Object time}) => 'Total progress (${time})';

  /// en: 'Finished with error'
  String get finishedError => 'Finished with error';

  /// en: 'Canceled by sender'
  String get canceledSender => 'Canceled by sender';

  /// en: 'Canceled by receiver'
  String get canceledReceiver => 'Canceled by receiver';
}

// Path: whatsNewPage.changes.v1_18_0
class Translations$whatsNewPage$changes$v1_18_0$en with WhatsNewStrings {
  Translations$whatsNewPage$changes$v1_18_0$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  @override
  List<String> get changes => [
    'Encryption no longer slows down transfers. It has been re-enabled on this device if you turned it off before.',
    'Requests from favorites are now accepted automatically. This is turned on by default and can be disabled in the settings.',
    'On Android, transfers continue while the app is in the background or the screen is off. On iOS, the app must still stay in the foreground.',
  ];
}
