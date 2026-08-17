// Файл: lib/models/job_model.dart

class JobModel {
  final String id;
  final String clientId; // Привязка к клиенту (Client-First)
  final String applianceType; // Холодильник, сушилка и т.д.
  final String brand;
  final String model;
  final String serialNumber;
  final String status;
  final String priority;
  final DateTime? scheduledDate;
  final String description;

  JobModel({
    required this.id,
    required this.clientId,
    required this.applianceType,
    this.brand = '',
    this.model = '',
    this.serialNumber = '',
    this.status = 'Вызов', // Статус по умолчанию
    this.priority = '🟢 Обычный',
    this.scheduledDate,
    this.description = '',
  });

  factory JobModel.fromMap(Map<String, dynamic> map, String documentId) {
    return JobModel(
      id: documentId,
      clientId: map['clientId'] ?? '',
      applianceType: map['applianceType'] ?? '',
      brand: map['brand'] ?? '',
      model: map['model'] ?? '',
      serialNumber: map['serialNumber'] ?? '',
      status: map['status'] ?? 'Вызов',
      priority: map['priority'] ?? '🟢 Обычный',
      // В Firebase даты хранятся как Timestamp, их нужно аккуратно переводить
      scheduledDate: map['scheduledDate'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              map['scheduledDate'].millisecondsSinceEpoch,
            )
          : null,
      description: map['description'] ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'clientId': clientId,
      'applianceType': applianceType,
      'brand': brand,
      'model': model,
      'serialNumber': serialNumber,
      'status': status,
      'priority': priority,
      'scheduledDate': scheduledDate,
      'description': description,
      'createdAt': DateTime.now(),
    };
  }
}
