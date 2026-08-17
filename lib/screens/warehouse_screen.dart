import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class WarehouseScreen extends StatefulWidget {
  const WarehouseScreen({super.key});

  @override
  State<WarehouseScreen> createState() => _WarehouseScreenState();
}

class _WarehouseScreenState extends State<WarehouseScreen> {
  // --- ДИАЛОГ ДОБАВЛЕНИЯ ИЛИ РЕДАКТИРОВАНИЯ ДЕТАЛИ ---
  void _showAddEditPartDialog({DocumentSnapshot? document}) {
    final isEdit = document != null;
    final data = isEdit ? document.data() as Map<String, dynamic> : {};

    final nameController = TextEditingController(
      text: isEdit ? data['name'] : '',
    );
    final costController = TextEditingController(
      text: isEdit ? (data['cost']?.toString() ?? '0') : '',
    );
    final priceController = TextEditingController(
      text: isEdit ? data['price'].toString() : '',
    );
    final quantityController = TextEditingController(
      text: isEdit ? data['quantity'].toString() : '1',
    );

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(
            isEdit ? 'Редактировать деталь' : 'Добавить на склад',
            style: const TextStyle(
              color: Color(0xFF14557F),
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Название детали (например: Помпа сливная LG)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: costController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Закупка (\$)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: priceController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Продажа (\$)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: quantityController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Количество на складе (шт)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final cost = double.tryParse(costController.text) ?? 0.0;
                final price = double.tryParse(priceController.text) ?? 0.0;
                final quantity = int.tryParse(quantityController.text) ?? 0;

                if (name.isNotEmpty) {
                  final partData = {
                    'name': name,
                    'cost': cost,
                    'price': price,
                    'quantity': quantity,
                    'updatedAt': FieldValue.serverTimestamp(),
                  };

                  final collection = FirebaseFirestore.instance
                      .collection('companies')
                      .doc('fix_appliance_ca')
                      .collection('warehouse');

                  if (isEdit) {
                    await collection.doc(document.id).update(partData);
                  } else {
                    await collection.add(partData);
                  }

                  if (context.mounted) Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFCC520),
                foregroundColor: Colors.black,
              ),
              child: Text(
                isEdit ? 'Сохранить' : 'Добавить',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- ФУНКЦИЯ УДАЛЕНИЯ ---
  void _deletePart(String docId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить деталь?'),
        content: const Text(
          'Вы уверены, что хотите полностью удалить эту позицию со склада?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          ElevatedButton(
            onPressed: () async {
              await FirebaseFirestore.instance
                  .collection('companies')
                  .doc('fix_appliance_ca')
                  .collection('warehouse')
                  .doc(docId)
                  .delete();
              if (context.mounted) Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
  }

  // --- БЫСТРОЕ ИЗМЕНЕНИЕ КОЛИЧЕСТВА (+ ИЛИ -) ---
  Future<void> _updateQuantity(String docId, int currentQty, int change) async {
    final newQty = currentQty + change;
    if (newQty >= 0) {
      await FirebaseFirestore.instance
          .collection('companies')
          .doc('fix_appliance_ca')
          .collection('warehouse')
          .doc(docId)
          .update({'quantity': newQty});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Склад запчастей',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: const Color(0xFF14557F),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('companies')
            .doc('fix_appliance_ca')
            .collection('warehouse')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFCC520)),
            );
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const Center(
              child: Text(
                'Склад пуст.\nНажмите + чтобы добавить запчасти.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            );
          }

          final parts = snapshot.data!.docs;

          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: parts.length,
            itemBuilder: (context, index) {
              final doc = parts[index];
              final data = doc.data() as Map<String, dynamic>;
              final quantity = data['quantity'] ?? 0;
              final cost = data['cost'] ?? 0.0;
              final price = data['price'] ?? 0.0;

              // Подсветка, если деталь закончилась
              final isOutOfStock = quantity == 0;

              return Card(
                elevation: 2,
                margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(
                    color: isOutOfStock
                        ? Colors.red.shade300
                        : Colors.grey.shade200,
                    width: isOutOfStock ? 2 : 1,
                  ),
                ),
                child: InkWell(
                  onTap: () => _showAddEditPartDialog(document: doc),
                  onLongPress: () => _deletePart(doc.id),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Row(
                      children: [
                        // Индикатор количества слева
                        Container(
                          width: 50,
                          height: 50,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isOutOfStock
                                ? Colors.red.shade50
                                : Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$quantity\nшт',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isOutOfStock
                                  ? Colors.red
                                  : const Color(0xFF14557F),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),

                        // Информация о детали
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data['name'] ?? 'Без названия',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    'Зак: \$${cost.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'Прод: \$${price.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      color: Colors.green,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // Кнопки плюс/минус
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.remove_circle_outline,
                                color: Colors.orange,
                              ),
                              onPressed: () =>
                                  _updateQuantity(doc.id, quantity, -1),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.add_circle_outline,
                                color: Colors.green,
                              ),
                              onPressed: () =>
                                  _updateQuantity(doc.id, quantity, 1),
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
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddEditPartDialog(),
        backgroundColor: const Color(0xFFFCC520),
        child: const Icon(Icons.add, color: Colors.black),
      ),
    );
  }
}
