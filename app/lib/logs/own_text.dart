// Words the owner typed, marked where they are shown (DECISIONS 757). Plain Flutter, no log inside.
import 'package:flutter/widgets.dart';

/// Words the owner typed (a tag, an experiment's line, a note, a channel's name), shown inside or beside a control.
/// The usage log never reads them: a tap's label skips whatever is under this widget, and a tooltip of a control
/// inside it. Put it round the text where it is shown, not round the whole row, so the row's own words still count.
class OwnText extends StatelessWidget {
  const OwnText({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
