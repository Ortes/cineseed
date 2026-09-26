import 'package:cineseed_shared/cineseed_shared.dart';
import 'package:flutter/material.dart';

import 'format_helpers.dart';
import 'search_sort.dart';

/// Below this viewport width the row stacks vertically (mobile layout).
const double _narrowBreakpoint = 480;

/// One release row: filename + parsed chips, age / size / seeders, Add button.
class ReleaseRow extends StatelessWidget {
  const ReleaseRow({
    super.key,
    required this.release,
    required this.onAdd,
    this.dense = false,
  });

  final TorrentResult release;
  final VoidCallback onAdd;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth < _narrowBreakpoint
            ? _buildNarrow(context)
            : _buildWide(context);
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    final tags = ReleaseTags.parse(release.title);
    final theme = Theme.of(context);
    return InkWell(
      onTap: onAdd,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 16,
          vertical: dense ? 6 : 10,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _TitleAndChips(release: release, tags: tags),
            ),
            SizedBox(
              width: 80,
              child: Text(
                fmtAge(release.pubDate),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(
              width: 110,
              child: Text(
                fmtSize(release.size),
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                '${release.seeders}',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: release.seeders > 0
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: IconButton(
                tooltip: 'Add to library',
                icon: const Icon(Icons.add_circle_outline),
                onPressed: onAdd,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final tags = ReleaseTags.parse(release.title);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final seedColor = release.seeders > 0
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onAdd,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, dense ? 8 : 12, 4, dense ? 8 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TitleAndChips(release: release, tags: tags),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(fmtAge(release.pubDate), style: muted),
                      Text('  ·  ', style: muted),
                      Text(fmtSize(release.size), style: muted),
                      Text('  ·  ', style: muted),
                      Icon(Icons.arrow_upward, size: 12, color: seedColor),
                      const SizedBox(width: 2),
                      Text(
                        '${release.seeders}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: seedColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Add to library',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

class _TitleAndChips extends StatelessWidget {
  const _TitleAndChips({required this.release, required this.tags});

  final TorrentResult release;
  final ReleaseTags tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          release.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
        if (tags.chips.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final c in tags.chips) MiniChip(label: c),
              if (tags.group != null) MiniChip(label: tags.group!, muted: true),
            ],
          ),
        ],
      ],
    );
  }
}

/// Small flat-coloured chip used to render parsed release tags.
class MiniChip extends StatelessWidget {
  const MiniChip({super.key, required this.label, this.muted = false});
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = muted
        ? theme.colorScheme.surfaceContainerHigh
        : theme.colorScheme.secondaryContainer;
    final fg = muted
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: fg),
      ),
    );
  }
}

/// Sortable column header bar (Name / Age / Size / Seed + Add gutter).
class ColumnHeader extends StatelessWidget {
  const ColumnHeader({
    super.key,
    required this.sortKey,
    required this.sortDesc,
    required this.onSort,
  });

  final SortKey sortKey;
  final bool sortDesc;
  final void Function(SortKey) onSort;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return constraints.maxWidth < _narrowBreakpoint
            ? _buildNarrow(context)
            : _buildWide(context);
      },
    );
  }

  Widget _buildWide(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: _HeaderLabel(
              label: 'Name',
              active: sortKey == SortKey.name,
              desc: sortDesc,
              onTap: () => onSort(SortKey.name),
            ),
          ),
          SizedBox(
            width: 80,
            child: Align(
              alignment: Alignment.centerRight,
              child: _HeaderLabel(
                label: 'Age',
                active: sortKey == SortKey.age,
                desc: sortDesc,
                onTap: () => onSort(SortKey.age),
              ),
            ),
          ),
          SizedBox(
            width: 110,
            child: Align(
              alignment: Alignment.centerRight,
              child: _HeaderLabel(
                label: 'Size',
                active: sortKey == SortKey.size,
                desc: sortDesc,
                onTap: () => onSort(SortKey.size),
              ),
            ),
          ),
          SizedBox(
            width: 64,
            child: Align(
              alignment: Alignment.centerRight,
              child: _HeaderLabel(
                label: 'Seed',
                active: sortKey == SortKey.seeders,
                desc: sortDesc,
                onTap: () => onSort(SortKey.seeders),
              ),
            ),
          ),
          const SizedBox(width: 56),
        ],
      ),
    );
  }

  Widget _buildNarrow(BuildContext context) {
    final theme = Theme.of(context);
    const labels = {
      SortKey.seeders: 'Seed',
      SortKey.size: 'Size',
      SortKey.age: 'Age',
      SortKey.name: 'Name',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          PopupMenuButton<SortKey>(
            tooltip: 'Sort by',
            onSelected: onSort,
            itemBuilder: (_) => [
              for (final entry in labels.entries)
                PopupMenuItem(
                  value: entry.key,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18,
                        child: entry.key == sortKey
                            ? Icon(
                                sortDesc
                                    ? Icons.arrow_downward
                                    : Icons.arrow_upward,
                                size: 14,
                                color: theme.colorScheme.primary,
                              )
                            : null,
                      ),
                      Text(entry.value),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.sort,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Sort: ${labels[sortKey]}',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Icon(
                    sortDesc ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel({
    required this.label,
    required this.active,
    required this.desc,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        active ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(color: color),
            ),
            if (active)
              Icon(
                desc ? Icons.arrow_drop_down : Icons.arrow_drop_up,
                size: 18,
                color: color,
              ),
          ],
        ),
      ),
    );
  }
}
