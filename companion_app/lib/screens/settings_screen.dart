import '../lib.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isIncognito = false; // Must live here, outside build()

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildNewSettings(
            context: context,
            title: 'Incognito mode',
            subtitle: 'Pauses reading history',
            icon: Icons.visibility_off_outlined,
            isToggle: true,
            toggleValue: _isIncognito,
            onToggleChanged: (val) {
              setState(() => _isIncognito = val);
            },
          ),
          const Divider(height: 1),
          _buildNewSettings(
            context: context,
            title: 'Download queue',
            icon: Icons.download_outlined,
            isToggle: false,
            onTap: () {
              debugPrint("Download Queue Pressed");
            },
          ),
        ],
      ),
    );
  }

  Widget _buildNewSettings({
    required BuildContext context,
    required String title,
    String? subtitle,
    required IconData icon,
    bool isToggle = true,
    bool toggleValue = false,
    ValueChanged<bool>? onToggleChanged,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    final titleWidget = Text(
      title,
      style: TextStyle(color: colorScheme.onSurface),
    );

    final subtitleWidget = subtitle != null
        ? Text(
            subtitle,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          )
        : null;

    final leadingIcon = Icon(icon, color: colorScheme.primary);

    if (isToggle) {
      return SwitchListTile(
        secondary:
            leadingIcon, // SwitchListTile uses `secondary`, not `leading`
        title: titleWidget,
        subtitle: subtitleWidget,
        value: toggleValue,
        onChanged: onToggleChanged,
      );
    }

    return ListTile(
      leading: leadingIcon,
      title: titleWidget,
      subtitle: subtitleWidget,
      trailing: Icon(
        Icons.arrow_forward_ios,
        size: 16,
        color: colorScheme.onSurfaceVariant,
      ),
      onTap: onTap,
    );
  }
}
