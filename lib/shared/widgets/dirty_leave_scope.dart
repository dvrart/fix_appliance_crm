import 'package:flutter/material.dart';

import '../unsaved_navigation_gate.dart';
import 'unsaved_changes_dialog.dart';

/// Blocks Back / tabs / menu while [dirty]. The chest sheet is the only way out:
/// green save, yellow stay, red discard.
class DirtyLeaveScope extends StatefulWidget {
  final bool dirty;
  final Future<bool> Function() onSave;
  final VoidCallback? onDiscard;
  final Widget child;
  final bool registerGate;
  final String? title;

  const DirtyLeaveScope({
    super.key,
    required this.dirty,
    required this.onSave,
    required this.child,
    this.onDiscard,
    this.registerGate = true,
    this.title,
  });

  static DirtyLeaveScopeState? of(BuildContext context) {
    return context.findAncestorStateOfType<DirtyLeaveScopeState>();
  }

  @override
  State<DirtyLeaveScope> createState() => DirtyLeaveScopeState();
}

class DirtyLeaveScopeState extends State<DirtyLeaveScope> {
  @override
  void initState() {
    super.initState();
    if (widget.registerGate) {
      UnsavedNavigationGate.push(_allowLeave);
    }
  }

  @override
  void dispose() {
    if (widget.registerGate) {
      UnsavedNavigationGate.pop(_allowLeave);
    }
    super.dispose();
  }

  Future<bool> _apply(
    UnsavedChangesAction action, {
    required bool pop,
  }) async {
    if (action == UnsavedChangesAction.cancel) return false;
    if (action == UnsavedChangesAction.save) {
      final route = ModalRoute.of(context);
      final ok = await widget.onSave();
      if (!ok) return false;
      // Editors pop themselves with a result. Extra pop would close the job card.
      if (pop && mounted && route != null && route.isCurrent) {
        Navigator.pop(context);
      }
      return true;
    }
    widget.onDiscard?.call();
    if (pop && mounted) Navigator.pop(context);
    return true;
  }

  Future<UnsavedChangesAction> _ask() {
    return showUnsavedChangesDialog(context, title: widget.title);
  }

  Future<bool> _allowLeave() async {
    if (!widget.dirty) return true;
    if (!mounted) return true;
    return _apply(await _ask(), pop: false);
  }

  Future<void> requestLeave() async {
    if (!widget.dirty) {
      if (mounted) Navigator.maybePop(context);
      return;
    }
    if (!mounted) return;
    await _apply(await _ask(), pop: true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        requestLeave();
      },
      child: widget.child,
    );
  }
}
