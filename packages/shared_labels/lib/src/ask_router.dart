// Who asks (DECISIONS 869). Today the app that holds the estimates asks its own questions ([SelfAskRouter]). Later,
// when eeg_tracker is linked to utof_tracker, its questions go to utof's check-in and it asks itself only when utof
// does not take them within about a day; that route is not built: [UtofAskRouter] is the place for it and always says
// "not linked".
import 'estimate.dart';

/// What became of a batch offered to the router.
enum AskDecision {
  /// This app asks: its notification and its card.
  askHere,

  /// Another app took the questions; this one stays quiet unless they come back unanswered.
  handedOver,
}

abstract interface class AskRouter {
  /// A short word for logs and settings: `self`, `utof`.
  String get name;

  /// Whether the other side is there and agreed to be asked; with false every batch is asked here.
  Future<bool> linked();

  /// Offers [batch] (with its questions' words as read at [at]); the answer says who asks.
  Future<AskDecision> offer(List<Estimate> batch, DateTime at);
}

/// The app asks its own questions.
class SelfAskRouter implements AskRouter {
  const SelfAskRouter();

  @override
  String get name => 'self';

  @override
  Future<bool> linked() async => false;

  @override
  Future<AskDecision> offer(List<Estimate> batch, DateTime at) async => AskDecision.askHere;
}

/// The hand-over to utof_tracker's check-in. Not built: never linked, so everything is asked here.
class UtofAskRouter implements AskRouter {
  const UtofAskRouter();

  /// Why it is not linked, for a settings line.
  String get why => 'not linked';

  @override
  String get name => 'utof';

  @override
  Future<bool> linked() async => false;

  @override
  Future<AskDecision> offer(List<Estimate> batch, DateTime at) async => AskDecision.askHere;
}
