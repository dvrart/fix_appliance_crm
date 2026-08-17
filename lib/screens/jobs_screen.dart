// Файл: lib/screens/jobs_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'job_details_screen.dart';
import 'create_job_screen.dart'; // Импортируем экран создания заявки

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> {
  String _selectedFilter = 'Все';

  Future<void> _makeCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // НАША ПЛАВАЮЩАЯ КНОПКА СОЗДАНИЯ РАБОТЫ ИЗ ТЗ
      body: Column(
        children: [
          Container(
            height: 60,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children:
                  [
                    'Все',
                    'Вызов',
                    'В работе',
                    'Ожидание запчасти',
                    'Завершено',
                  ].map((status) {
                    final isSelected = _selectedFilter == status;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilterChip(
                        label: Text(status),
                        selected: isSelected,
                        selectedColor: const Color(0xFFFCC520),
                        checkmarkColor: Colors.black,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.black : Colors.black87,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        onSelected: (bool selected) {
                          setState(() {
                            _selectedFilter = status;
                          });
                        },
                      ),
                    );
                  }).toList(),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('companies')
                  .doc('fix_appliance_ca')
                  .collection('jobs')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                }

                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Ошибка загрузки списка работ'),
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.build_circle_outlined,
                          size: 80,
                          color: Colors.grey,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Нет активных работ.\nСоздайте их в один клик кнопкой ниже.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 16),
                        ),
                      ],
                    ),
                  );
                }

                final allJobs = snapshot.data!.docs;
                final filteredJobs = _selectedFilter == 'Все'
                    ? allJobs
                    : allJobs.where((doc) {
                        final data = doc.data() as Map<String, dynamic>;
                        return data['status'] == _selectedFilter;
                      }).toList();

                if (filteredJobs.isEmpty) {
                  return const Center(
                    child: Text('Нет работ с таким статусом'),
                  );
                }

                return ListView.builder(
                  itemCount: filteredJobs.length,
                  itemBuilder: (context, index) {
                    final jobData =
                        filteredJobs[index].data() as Map<String, dynamic>;
                    final priority = jobData['priority'] ?? '🟢 Обычный';
                    final status = jobData['status'] ?? 'Вызов';
                    final clientPhone = jobData['clientPhone'] ?? '';

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      elevation: 3,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(
                          color: _getPriorityColor(priority),
                          width: 1.5,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => JobDetailsScreen(
                                jobId: filteredJobs[index].id,
                                clientId: jobData['clientId'],
                                jobData: jobData,
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '${jobData['applianceType']} ${jobData['brand']}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF14557F),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _getStatusColor(
                                        status,
                                      ).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: _getStatusColor(status),
                                      ),
                                    ),
                                    child: Text(
                                      status,
                                      style: TextStyle(
                                        color: _getStatusColor(status),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Клиент: ${jobData['clientName'] ?? 'Не указан'}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                jobData['description'] ?? 'Без описания',
                                style: const TextStyle(color: Colors.black54),
                              ),
                              const Divider(height: 24),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Приоритет: $priority',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (clientPhone.isNotEmpty)
                                    ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF14557F,
                                        ),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                      ),
                                      onPressed: () => _makeCall(clientPhone),
                                      icon: const Icon(Icons.phone, size: 18),
                                      label: const Text('Позвонить'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Color _getPriorityColor(String priority) {
    if (priority.contains('🔴')) return const Color(0xFF791B29);
    if (priority.contains('🟡')) return const Color(0xFFFCC520);
    return Colors.green;
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Вызов':
        return Colors.blue;
      case 'В работе':
        return const Color(0xFFFCC520);
      case 'Ожидание запчасти':
        return Colors.orange;
      case 'Завершено':
        return Colors.green;
      default:
        return Colors.grey;
    }
  }
}
