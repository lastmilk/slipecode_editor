import 'package:flutter/material.dart';

import '../payloads/loader/loader_payload.dart';

/// 按参数定义自动生成的表单（底部弹层）
class PayloadParamsSheet extends StatefulWidget {
  final String title;
  final List<PayloadParamDef> defs;
  final Map<String, String> values;
  final VoidCallback? onChanged;

  const PayloadParamsSheet({
    super.key,
    required this.title,
    required this.defs,
    required this.values,
    this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required List<PayloadParamDef> defs,
    required Map<String, String> values,
    VoidCallback? onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: PayloadParamsSheet(
          title: title,
          defs: defs,
          values: values,
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  State<PayloadParamsSheet> createState() => _PayloadParamsSheetState();
}

class _PayloadParamsSheetState extends State<PayloadParamsSheet> {
  String _valueOf(PayloadParamDef def) =>
      widget.values[def.key] ?? def.defaultValue;

  void _set(PayloadParamDef def, String value) {
    setState(() => widget.values[def.key] = value);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            if (widget.defs.isEmpty)
              const Text('该 Payload 无可配置参数',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            for (final def in widget.defs) _buildField(def),
          ],
        ),
      ),
    );
  }

  Widget _buildField(PayloadParamDef def) {
    switch (def.type) {
      case PayloadParamType.bool:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(def.label, style: const TextStyle(fontSize: 14)),
          subtitle: def.hint.isEmpty
              ? null
              : Text(def.hint, style: const TextStyle(fontSize: 11)),
          value: _valueOf(def) == 'true',
          onChanged: (v) => _set(def, v ? 'true' : 'false'),
        );
      case PayloadParamType.select:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<String>(
            initialValue:
                def.options.contains(_valueOf(def)) ? _valueOf(def) : null,
            decoration: InputDecoration(
              labelText: def.label,
              helperText: def.hint.isEmpty ? null : def.hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: def.options
                .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                .toList(),
            onChanged: (v) {
              if (v != null) _set(def, v);
            },
          ),
        );
      case PayloadParamType.multiSelect:
        final selected = _valueOf(def)
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(def.label, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final option in def.options)
                    FilterChip(
                      label:
                          Text(option, style: const TextStyle(fontSize: 12)),
                      selected: selected.contains(option),
                      onSelected: (v) {
                        if (v) {
                          selected.add(option);
                        } else {
                          selected.remove(option);
                        }
                        _set(def, selected.join(','));
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      case PayloadParamType.text:
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            initialValue: _valueOf(def),
            decoration: InputDecoration(
              labelText: def.label,
              hintText: def.hint.isEmpty ? null : def.hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => _set(def, v),
          ),
        );
    }
  }
}
