import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/ptndesk.dart';

// Blocking labcode enrollment. Shown once (until enrolled) over the locked home.
Future<void> showPtndeskEnrollDialog(BuildContext context) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(canPop: false, child: _PtndeskEnrollDialog()),
  );
}

class _PtndeskEnrollDialog extends StatefulWidget {
  const _PtndeskEnrollDialog();
  @override
  State<_PtndeskEnrollDialog> createState() => _PtndeskEnrollDialogState();
}

class _PtndeskEnrollDialogState extends State<_PtndeskEnrollDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String _error = '';

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    String err;
    try {
      err = await ptndeskEnroll(_controller.text);
    } catch (_) {
      err = 'خطای غیرمنتظره';
    }
    if (!mounted) return;
    if (err.isEmpty) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('فعال‌سازی پشتیبانی'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('برای اتصال، کد آزمایشگاه خود را وارد کنید.'),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                enabled: !_busy,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'کد آزمایشگاه',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _busy ? null : _submit(),
              ),
              if (_error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error, style: const TextStyle(color: Colors.red)),
                ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('تأیید'),
          ),
        ],
      ),
    );
  }
}
