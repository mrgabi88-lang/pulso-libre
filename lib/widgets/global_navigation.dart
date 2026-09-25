import 'package:flutter/material.dart';

import 'brand_style.dart';

/// Keeps screen controls clear of the floating destinations, including on QR
/// and event screens. Decorative backgrounds still fill the entire viewport.
const globalNavigationInset = 72.0;

class GlobalNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onNavigate;

  const GlobalNavigation({
    super.key,
    required this.selectedIndex,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
    minimum: const EdgeInsets.all(12),
    child: Align(
      alignment: Alignment.centerRight,
      child: SingleChildScrollView(
        primary: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            key: const ValueKey('global-navigation'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (id, name, label, icon) in [
                (1, 'events', 'Eventos', Icons.event),
                (2, 'buy', 'Comprar', Icons.shopping_bag_outlined),
                (3, 'tickets', 'Entradas', Icons.qr_code_2),
                (4, 'account', 'Cuenta', Icons.person_outline),
              ]) ...[
                if (id > 1) const SizedBox(height: 12),
                Material(
                  color: selectedIndex == id
                      ? const Color(0xFF25223B)
                      : const Color(0xF00C0D16),
                  elevation: 5,
                  shadowColor: Colors.black54,
                  shape: CircleBorder(
                    side: BorderSide(
                      color: selectedIndex == id
                          ? (id.isEven ? brandBlue : brandPink)
                          : const Color(0xFF414353),
                      width: selectedIndex == id ? 2 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    key: ValueKey('global-nav-$name'),
                    tooltip: label,
                    isSelected: selectedIndex == id,
                    onPressed: () {
                      if (selectedIndex != id) {
                        FocusManager.instance.primaryFocus?.unfocus();
                        onNavigate(id);
                      }
                    },
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: Icon(
                      icon,
                      color: id.isEven ? brandBlue : brandPink,
                      size: 26,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
