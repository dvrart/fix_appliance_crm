import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/utils/formatters.dart';

/// Экран для клиента: чаевые выбирают до списания карты / ссылки / наличных.
class ClientTipPage extends StatefulWidget {
  final double due;

  const ClientTipPage({super.key, required this.due});

  static Future<double?> ask(BuildContext context, {required double due}) {
    return Navigator.of(context, rootNavigator: true).push<double>(
      MaterialPageRoute(
        builder: (_) => ClientTipPage(due: due),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<ClientTipPage> createState() => _ClientTipPageState();
}

class _ClientTipPageState extends State<ClientTipPage> {
  int? _percent;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  double get _tip {
    if (_percent != null) {
      return double.parse((widget.due * _percent! / 100).toStringAsFixed(2));
    }
    return double.tryParse(_custom.text.replaceAll(',', '.')) ?? 0;
  }

  double get _total => widget.due + _tip;

  void _choosePercent(int percent) {
    setState(() {
      _percent = percent;
      _custom.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Add a tip'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Would you like to leave a tip?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Repair  ${Formatters.formatCurrency(widget.due)}',
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  for (final pct in [15, 18, 20])
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: pct == 20 ? 0 : 8),
                        child: _pctButton(pct),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _custom,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                style: const TextStyle(color: Colors.white, fontSize: 20),
                onChanged: (_) => setState(() => _percent = null),
                decoration: InputDecoration(
                  labelText: 'Custom amount',
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixText: '\$ ',
                  prefixStyle: const TextStyle(color: Colors.white, fontSize: 20),
                  filled: true,
                  fillColor: Colors.white12,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'Tip  ${Formatters.formatCurrency(_tip)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 4),
              Text(
                Formatters.formatCurrency(_total),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context, _tip),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFACC15),
                    foregroundColor: Colors.black,
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  child: Text(
                    _tip <= 0
                        ? 'Continue without a tip'
                        : 'Pay ${Formatters.formatCurrency(_total)}',
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 0.0),
                child: const Text(
                  'No tip',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pctButton(int percent) {
    final selected = _percent == percent;
    final amount = widget.due * percent / 100;
    return Material(
      color: selected ? const Color(0xFFFACC15) : Colors.white12,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _choosePercent(percent),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.black : Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                Formatters.formatCurrency(amount),
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? Colors.black87 : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
