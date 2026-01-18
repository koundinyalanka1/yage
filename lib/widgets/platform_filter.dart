import 'package:flutter/material.dart';

import '../core/mgba_bindings.dart';
import '../utils/theme.dart';

/// Platform filter chips for game library
class PlatformFilter extends StatelessWidget {
  final GamePlatform? selectedPlatform;
  final void Function(GamePlatform?) onChanged;

  const PlatformFilter({
    super.key,
    required this.selectedPlatform,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _FilterChip(
            label: 'All',
            isSelected: selectedPlatform == null,
            color: YageColors.primary,
            onTap: () => onChanged(null),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GBA',
            isSelected: selectedPlatform == GamePlatform.gba,
            color: YageColors.gbaColor,
            onTap: () => onChanged(GamePlatform.gba),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GBC',
            isSelected: selectedPlatform == GamePlatform.gbc,
            color: YageColors.gbcColor,
            onTap: () => onChanged(GamePlatform.gbc),
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'GB',
            isSelected: selectedPlatform == GamePlatform.gb,
            color: YageColors.gbColor,
            onTap: () => onChanged(GamePlatform.gb),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final Color color;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: isSelected ? color : YageColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? color : YageColors.surfaceLight,
                width: 2,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: color.withOpacity(0.4),
                        blurRadius: 8,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: isSelected 
                    ? YageColors.backgroundDark 
                    : YageColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

