import 'package:localsend_app/model/state/purchase_state.dart';
import 'package:refena_flutter/refena_flutter.dart';

class DonationPageVm {
  final bool platformSupportPayment;
  final Map<PurchaseItem, String> prices;
  final Set<PurchaseItem> purchased;
  final bool pending;
  final void Function(PurchaseItem item) purchase;
  final void Function() restore;

  DonationPageVm({
    required this.platformSupportPayment,
    required this.prices,
    required this.purchased,
    required this.pending,
    required this.purchase,
    required this.restore,
  });
}

/// This is a noop version of the original view model.
/// shareMe: the in-app purchase version was removed, like LocalSend's FOSS build (see docs/telemetry-google.md).
final donationPageNoopVmProvider = ViewProvider<DonationPageVm>((ref) {
  return DonationPageVm(
    platformSupportPayment: false,
    prices: {},
    purchased: {},
    pending: false,
    purchase: (_) {},
    restore: () {},
  );
});
