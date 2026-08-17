// Файл: lib/screens/reports_screen.dart
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  String _selectedFilter = 'День'; // По умолчанию ставим День
  final List<String> _filters = ['День', 'Неделя', 'Месяц', 'Год'];

  // Переменная для выбранной даты (по умолчанию сегодня)
  DateTime _selectedDate = DateTime.now();

  // Данные для отображения
  double _totalIncome = 0.0;
  double _totalExpenses = 0.0;
  int _completedJobsCount = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Финансовый отчет',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // 1. БЛОК ВЕРХНИХ ФИЛЬТРОВ
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: _filters.map((filter) {
                final isSelected = _selectedFilter == filter;
                return ChoiceChip(
                  label: Text(
                    filter,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: const Color(0xFF14557F),
                  backgroundColor: Colors.grey.shade200,
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _selectedFilter = filter;
                        // Сбрасываем дату на сегодня при переключении фильтров
                        _selectedDate = DateTime.now();
                      });
                    }
                  },
                );
              }).toList(),
            ),
          ),

          // 2. БЛОК ВЫБОРА КОНКРЕТНОГО ДНЯ (Отображается только если выбран фильтр "День")
          if (_selectedFilter == 'День')
            Container(
              color: Colors.white,
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_left,
                      size: 30,
                      color: Color(0xFF14557F),
                    ),
                    onPressed: () {
                      setState(() {
                        _selectedDate = _selectedDate.subtract(
                          const Duration(days: 1),
                        );
                      });
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(
                      Icons.calendar_month,
                      color: Color(0xFF14557F),
                    ),
                    label: Text(
                      "${_selectedDate.day.toString().padLeft(2, '0')}.${_selectedDate.month.toString().padLeft(2, '0')}.${_selectedDate.year}",
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF14557F),
                      ),
                    ),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.light(
                                primary: Color(0xFF14557F),
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null) {
                        setState(() {
                          _selectedDate = picked;
                        });
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_right,
                      size: 30,
                      color: Color(0xFF14557F),
                    ),
                    onPressed: () {
                      setState(() {
                        _selectedDate = _selectedDate.add(
                          const Duration(days: 1),
                        );
                      });
                    },
                  ),
                ],
              ),
            ),
          const Divider(height: 1),

          // 3. ОСНОВНОЙ КОНТЕНТ С ЦИФРАМИ
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collectionGroup('jobs')
                  .where('companyId', isEqualTo: 'fix_appliance_ca')
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFCC520)),
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _buildEmptyState();
                }

                // Передаем все работы в функцию подсчета (она сама отфильтрует по выбранному дню)
                _calculateMetrics(snapshot.data!.docs);

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // КАРТОЧКИ ИТОГОВ
                      Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              'Доход',
                              _totalIncome,
                              Colors.green,
                              Icons.arrow_downward,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Расход (Детали)',
                              _totalExpenses,
                              Colors.red,
                              Icons.arrow_upward,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF14557F),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            const Text(
                              'ЧИСТАЯ ПРИБЫЛЬ',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '\$${(_totalIncome - _totalExpenses).toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: Color(0xFFFCC520),
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Завершено работ: $_completedJobsCount',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),

                      // ГРАФИК
                      const Text(
                        'График выручки',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF14557F),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        height: 250,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.shade200,
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: BarChart(
                          BarChartData(
                            alignment: BarChartAlignment.spaceAround,
                            maxY: _totalIncome == 0
                                ? 100.0
                                : _totalIncome * 1.2,
                            barTouchData: BarTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              show: true,
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  getTitlesWidget:
                                      (double value, TitleMeta meta) {
                                        const style = TextStyle(
                                          color: Colors.grey,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                        );
                                        String text;
                                        switch (value.toInt()) {
                                          case 0:
                                            text = 'Пн';
                                            break;
                                          case 1:
                                            text = 'Вт';
                                            break;
                                          case 2:
                                            text = 'Ср';
                                            break;
                                          case 3:
                                            text = 'Чт';
                                            break;
                                          case 4:
                                            text = 'Пт';
                                            break;
                                          case 5:
                                            text = 'Сб';
                                            break;
                                          case 6:
                                            text = 'Вс';
                                            break;
                                          default:
                                            text = '';
                                            break;
                                        }
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            top: 8.0,
                                          ),
                                          child: Text(text, style: style),
                                        );
                                      },
                                ),
                              ),
                              leftTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            barGroups: [
                              _buildBarGroup(0, _totalIncome * 0.1),
                              _buildBarGroup(1, _totalIncome * 0.3),
                              _buildBarGroup(2, _totalIncome * 0.2),
                              _buildBarGroup(3, _totalIncome * 0.5),
                              _buildBarGroup(4, _totalIncome * 0.8),
                              _buildBarGroup(5, _totalIncome),
                              _buildBarGroup(6, _totalIncome * 0.4),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  BarChartGroupData _buildBarGroup(int x, double y) {
    return BarChartGroupData(
      x: x,
      barRods: [
        BarChartRodData(
          toY: y,
          color: const Color(0xFFFCC520),
          width: 16,
          borderRadius: BorderRadius.circular(4),
          backDrawRodData: BackgroundBarChartRodData(
            show: true,
            toY: _totalIncome == 0 ? 100.0 : _totalIncome * 1.2,
            color: Colors.grey.shade100,
          ),
        ),
      ],
    );
  }

  void _calculateMetrics(List<DocumentSnapshot> docs) {
    double income = 0.0;
    double expenses = 0.0;
    int completed = 0;

    final now = DateTime.now();

    for (var doc in docs) {
      final data = doc.data() as Map<String, dynamic>;

      DateTime jobDate = now;
      if (data['createdAt'] != null) {
        jobDate = (data['createdAt'] as Timestamp).toDate();
      }

      bool matchesFilter = false;

      // ЛОГИКА ФИЛЬТРАЦИИ И ПОИСКА ДЛЯ ВЫБРАННОГО ДНЯ
      if (_selectedFilter == 'День') {
        if (jobDate.year == _selectedDate.year &&
            jobDate.month == _selectedDate.month &&
            jobDate.day == _selectedDate.day) {
          matchesFilter = true;
        }
      } else if (_selectedFilter == 'Неделя' &&
          now.difference(jobDate).inDays <= 7) {
        matchesFilter = true;
      } else if (_selectedFilter == 'Месяц' &&
          now.difference(jobDate).inDays <= 30) {
        matchesFilter = true;
      } else if (_selectedFilter == 'Год' &&
          now.difference(jobDate).inDays <= 365) {
        matchesFilter = true;
      }

      if (matchesFilter) {
        if (data['status'] == 'Завершено') completed++;

        if (data['financeItems'] != null) {
          final items = data['financeItems'] as List;
          for (var item in items) {
            income += num.parse(item['price'].toString()).toDouble();
            if (item['type'] == 'Запчасть') {
              expenses += num.parse(item['price'].toString()).toDouble() * 0.4;
            }
          }
        }
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          (_totalIncome != income ||
              _totalExpenses != expenses ||
              _completedJobsCount != completed)) {
        setState(() {
          _totalIncome = income;
          _totalExpenses = expenses;
          _completedJobsCount = completed;
        });
      }
    });
  }

  Widget _buildSummaryCard(
    String title,
    double amount,
    Color iconColor,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 10,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: 4),
              Text(
                title,
                style: const TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_chart_outlined, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'За выбранный период нет данных.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
