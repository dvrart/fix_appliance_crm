import 'package:flutter/material.dart';

/// Обучение секретаря — без папки «ошибок».
class SecretaryLearnPage extends StatelessWidget {
  const SecretaryLearnPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Обучение секретаря'),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
        toolbarHeight: 48,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        children: const [
          Text(
            'СЕКРЕТАРЬ',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.grey,
              fontSize: 13,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 12),
          _LearnCard(
            icon: Icons.record_voice_over,
            title: 'Правила ответа',
            subtitle:
                'Как секретарь здоровается, что спрашивает и когда передаёт мастеру.',
          ),
          SizedBox(height: 12),
          _LearnCard(
            icon: Icons.school_outlined,
            title: 'Обучение',
            subtitle:
                'После звонка секретарь предлагает, чему научиться. Скрипт меняется только после вашего «да».',
          ),
        ],
      ),
    );
  }
}

class _LearnCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _LearnCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation: 1,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFF14557F).withValues(alpha: 0.1),
          child: Icon(icon, color: const Color(0xFF14557F)),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
      ),
    );
  }
}
