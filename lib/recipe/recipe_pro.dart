import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import 'recipe_account.dart';

/// RevenueCat's public SDK keys, one per store. Safe to compile in, like the
/// Supabase publishable key; the secret one lives on the server, which is what
/// actually decides whether a recipe is written.
const _appleKey = String.fromEnvironment('REVENUECAT_APPLE_KEY');
const _googleKey = String.fromEnvironment('REVENUECAT_GOOGLE_KEY');

/// The entitlement both subscriptions unlock — `ENTITLEMENT` in
/// server/app/usage.py.
const _entitlement = 'pro';

/// Whether this build can sell Pro. Off with no accounts or no key for this
/// platform, which is every run of `flutter test` and the desktop harness —
/// the empty-`PHOTO_PROXY` rule.
bool get proOn =>
    accountsOn &&
    (Platform.isIOS ? _appleKey : (Platform.isAndroid ? _googleKey : ''))
        .isNotEmpty;

/// When this phone's Pro ends, or null when it isn't Pro. Only for showing:
/// the server asks RevenueCat itself and never takes the phone's word.
final proUntil = ValueNotifier<DateTime?>(null);

String? _user;

/// Follows [account] into RevenueCat, so a purchase lands on the Supabase
/// user id the server will ask about. A sign-out or a switch to another
/// phone's account is a new id, and `logIn` moves RevenueCat with it.
void startPro() {
  if (!proOn) return;
  account.addListener(() => unawaited(_follow()));
  unawaited(_follow());
}

Future<void> _follow() async {
  final id = account.value?.id;
  // A token refresh re-announces the same account.
  if (id == null || id == _user) return;
  final first = _user == null;
  _user = id;
  try {
    if (first) {
      await Purchases.configure(
        PurchasesConfiguration(Platform.isIOS ? _appleKey : _googleKey)
          ..appUserID = id,
      );
      Purchases.addCustomerInfoUpdateListener(_show);
      _show(await Purchases.getCustomerInfo());
    } else {
      _show((await Purchases.logIn(id)).customerInfo);
    }
  } catch (e) {
    debugPrint('RevenueCat sign-in failed: $e');
  }
}

void _show(CustomerInfo info) {
  final expires = info.entitlements.active[_entitlement]?.expirationDate;
  proUntil.value = expires == null ? null : DateTime.parse(expires);
}

/// What the store sells right now, monthly before annual as RevenueCat's
/// default offering lists them. Empty when the store can't be reached.
Future<List<Package>> proPackages() async {
  final offerings = await Purchases.getOfferings();
  return offerings.current?.availablePackages ?? const [];
}

/// True once [package] is bought; false when the cook backed out of the
/// store's sheet. Anything else throws.
Future<bool> buyPro(Package package) async {
  try {
    _show(
      (await Purchases.purchase(PurchaseParams.package(package))).customerInfo,
    );
  } on PlatformException catch (e) {
    if (PurchasesErrorHelper.getErrorCode(e) ==
        PurchasesErrorCode.purchaseCancelledError) {
      return false;
    }
    rethrow;
  }
  return proUntil.value != null;
}

/// Brings back a subscription bought on this store account — after a
/// reinstall that started a new anonymous user, RevenueCat moves it onto this
/// one. True when that made this phone Pro.
Future<bool> restorePro() async {
  _show(await Purchases.restorePurchases());
  return proUntil.value != null;
}
