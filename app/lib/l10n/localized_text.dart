import 'package:flutter/widgets.dart';
import 'app_strings.dart';
import 'ui_message.dart';

/// Renders a descriptor against the CURRENT inherited localization.
/// Use inside popup items / SnackBars / builders whose surrounding code
/// crossed an await, so the text follows a language switch even while the
/// route stays open (I18N-PLAN §4.5). This is a Localizations dependency,
/// NOT a Riverpod listener.
class LocalizedText extends StatelessWidget {
  const LocalizedText(this.message, {super.key, this.style, this.textAlign});

  final UiMessage message;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
    AppStrings.of(context).render(message),
    style: style,
    textAlign: textAlign,
  );
}
