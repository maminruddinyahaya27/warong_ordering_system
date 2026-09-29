import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/bluetooth_printer_manager.dart';
import '../services/hub_auth.dart';
import '../services/menu_sync_service.dart';
import 'hub_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsStore settings = SettingsStore.instance;

  late final TextEditingController _restaurantName;
  late final TextEditingController _currency;
  late final TextEditingController _footer;
  late final TextEditingController _taxRate;
  late final TextEditingController _roundingStep;
  late final TextEditingController _cooldown;
  late final TextEditingController _keepAwake;
  late final TextEditingController _portalUrl;
  late final TextEditingController _portalUser;
  late final TextEditingController _portalPass;
  late final TextEditingController _hubUser;
  late final TextEditingController _hubPass;

  bool _taxInclusive = false;
  bool _autoMerge = true;
  bool _acceptQrOrders = false;
  String _ticketSize = 'large';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _restaurantName = TextEditingController(text: settings.restaurantName);
    _currency = TextEditingController(text: settings.currency);
    _footer = TextEditingController(text: settings.receiptFooter);
    _taxRate = TextEditingController(
        text: (settings.taxRate * 100).toStringAsFixed(2));
    _roundingStep = TextEditingController(
        text: settings.roundingStep.toStringAsFixed(2));
    _portalUrl = TextEditingController(text: settings.portalUrl);
    _portalUser = TextEditingController(text: settings.portalUser);
    _portalPass = TextEditingController(text: settings.portalPass);
    _hubUser = TextEditingController(text: settings.hubUser);
    _hubPass = TextEditingController(text: settings.hubPass);
    _cooldown = TextEditingController(
        text: settings.printerCooldownMs.toString());
    _keepAwake =
        TextEditingController(text: settings.keepAwakeMinutes.toString());
    _taxInclusive = settings.taxInclusive;
    _autoMerge = settings.autoMergeTableOrders;
    _acceptQrOrders = settings.acceptQrOrders;
    _ticketSize = settings.ticketTextSize;
  }

  @override
  void dispose() {
    for (final controller in [
      _restaurantName,
      _currency,
      _footer,
      _taxRate,
      _roundingStep,
      _cooldown,
      _keepAwake,
      _portalUrl,
      _portalUser,
      _portalPass,
      _hubUser,
      _hubPass,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final taxPercent = double.tryParse(_taxRate.text.trim());
    if (taxPercent == null || taxPercent < 0) {
      _snack('Tax rate must be a number (e.g. 10)');
      return;
    }
    final rounding = double.tryParse(_roundingStep.text.trim()) ?? 0;
    final cooldown = int.tryParse(_cooldown.text.trim()) ?? 1500;
    final keepAwake = int.tryParse(_keepAwake.text.trim()) ?? 30;

    setState(() => _saving = true);
    try {
      await settings.save({
        'restaurant_name': _restaurantName.text.trim(),
        'currency': _currency.text.trim(),
        'receipt_footer': _footer.text.trim(),
        'tax_rate': (taxPercent / 100).toString(),
        'tax_inclusive': _taxInclusive ? 'true' : 'false',
        'rounding_step': rounding.toString(),
        'printer_cooldown_ms': cooldown.toString(),
        'ticket_text_size': _ticketSize,
        'keep_awake_minutes': keepAwake.toString(),
        'auto_merge_table_orders': _autoMerge ? 'true' : 'false',
        'accept_qr_orders': _acceptQrOrders ? 'true' : 'false',
        'portal_url': _portalUrl.text.trim(),
        'portal_user': _portalUser.text.trim(),
        'portal_pass': _portalPass.text,
        'hub_user': _hubUser.text.trim(),
        'hub_pass': _hubPass.text,
      });

      HubAuth.configure(
        user: settings.hubUser,
        pass: settings.hubPass,
      );
      BluetoothPrinterManager.instance.throttle.cooldownMs =
          settings.printerCooldownMs;

      if (mounted) {
        _snack('Settings saved');
        Navigator.of(context).pop(true);
      }

      // Pull the menu in the background so a slow or unreachable portal can
      // never block saving. The Hub screen shows the item count and any error.
      if (settings.portalUrl.isNotEmpty) {
        unawaited(MenuSyncService.instance.syncQuietly());
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Receipt'),
          _text(_restaurantName, 'Restaurant name'),
          _text(_currency, 'Currency symbol', width: 120),
          _text(_footer, 'Receipt footer'),
          const SizedBox(height: 8),
          _sectionTitle('Tax & rounding'),
          Row(
            children: [
              Expanded(child: _text(_taxRate, 'Tax rate (%)')),
              const SizedBox(width: 12),
              Expanded(child: _text(_roundingStep, 'Cash rounding step')),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Prices already include tax'),
            subtitle: const Text('When on, tax is backed out of the price'),
            value: _taxInclusive,
            onChanged: (value) => setState(() => _taxInclusive = value),
          ),
          const Divider(height: 32),
          _sectionTitle('Printing'),
          _text(_cooldown, 'Delay between prints (ms)',
              hint: '1500'),
          const Text(
            'Gap enforced between two prints to the same printer. Classic '
            'Bluetooth printers need it when stations share one device — '
            'raise it if a shared printer still misses tickets.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          _dropdown(
            label: 'Ticket text size (kitchen tickets)',
            value: _ticketSize,
            options: const ['normal', 'large', 'huge'],
            onChanged: (value) => setState(() => _ticketSize = value),
          ),
          const Text(
            'How large item lines print on station tickets. "large" is twice '
            'the height and keeps the 32-column layout; "huge" also doubles the '
            'width, so long item names wrap.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          _text(_keepAwake, 'Keep screen on for (minutes)',
              hint: '30'),
          const Text(
            'The tablet screen stays awake while the till is in use, then is '
            'released after this many minutes without a touch.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          const Divider(height: 32),
          _sectionTitle('Ordering'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('One bill per table'),
            subtitle: const Text(
              'New dine-in orders for a table that still has an open bill are '
              'added to it, so the table pays on a single receipt.',
            ),
            value: _autoMerge,
            onChanged: (value) => setState(() => _autoMerge = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Accept QR table orders'),
            subtitle: const Text(
              'Import orders customers send by scanning a table QR code, and '
              'print their kitchen tickets. Needs the portal URL and an API key '
              'or portal login above. Customers pay at the counter.',
            ),
            value: _acceptQrOrders,
            onChanged: (value) => setState(() => _acceptQrOrders = value),
          ),
          const Divider(height: 32),
          _sectionTitle('Menu source (portal)'),
          _text(_portalUrl, 'Portal base URL',
              hint: 'http://192.168.1.10:3000'),
          Row(
            children: [
              Expanded(child: _text(_portalUser, 'Portal user')),
              const SizedBox(width: 12),
              Expanded(child: _text(_portalPass, 'Portal password', obscure: true)),
            ],
          ),
          const Divider(height: 32),
          _sectionTitle('Hub access (devices → this tablet)'),
          const Text(
            'Leave both blank to run without authentication on a trusted LAN. '
            'When set, waiter devices must use the same credentials.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _text(_hubUser, 'Hub user')),
              const SizedBox(width: 12),
              Expanded(child: _text(_hubPass, 'Hub password', obscure: true)),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            label: const Text('Save settings'),
          ),
          const Divider(height: 40),
          const Text(
            'Hub',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            'Server, Bluetooth printers, station assignments and the print queue.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          const HubScreen(embedded: true),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
      );

  Widget _text(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
    double? width,
  }) {
    final field = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
    if (width == null) return field;
    return SizedBox(width: width, child: field);
  }

  Widget _dropdown({
    required String label,
    required String value,
    required List<String> options,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: options
            .map((option) =>
                DropdownMenuItem(value: option, child: Text(option)))
            .toList(),
        onChanged: (selected) {
          if (selected != null) onChanged(selected);
        },
      ),
    );
  }
}
