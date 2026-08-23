import 'package:flutter/material.dart';

import 'assistant_session.dart';

class AssistantHost {
  AssistantHost._();

  /// Не открывает окно — только включает/выключает смайлик в шапке.
  static VoidCallback? opener(BuildContext context) {
    return () {
      AssistantSession.instance.toggle();
    };
  }
}
