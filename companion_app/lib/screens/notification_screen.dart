import '../lib.dart';

class NotificationPage extends StatelessWidget {
  const NotificationPage({super.key, required this.service});

  final WasteConnectionService service;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '18 Nov 2026', // Or your date variable
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey,
                  ),
                ),
              ),
              const Divider(
                height: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
              ),
              _buildNewNotifications(
                  title: "Sampah 1", subtitle: "Penuh", isNew: true)
            ],
          );
        },
      ),
    );
  }

  Widget _buildNewNotifications({
    required String title,
    required String subtitle,
    bool isNew = false,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        _buildNewBadge(isNew: isNew),
        const SizedBox(width: 8),
        const Icon(Icons.arrow_forward_ios, size: 16),
      ]),
      onTap: () {
        // Handle tap action
        debugPrint('Tapped $title');
      },
      tileColor: Colors.transparent,
    );
  }

  Widget _buildNewBadge({bool isNew = true}) {
    if (!isNew) return const SizedBox.shrink(); // Hides pill if not new

    const Color color =
        Color(0xFF00E676); // Or Colors.amberAccent / Colors.redAccent

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: const Text(
        'NEW',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
