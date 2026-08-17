// Файл: lib/models/client_model.dart

class ClientModel {
  final String id; // ID документа в Firebase
  final String companyId; // ID твоей компании (Multi-company)
  final String fullName;
  final String phone;
  final String address;
  final String email;
  final String companyName;

  ClientModel({
    required this.id,
    required this.companyId,
    required this.fullName,
    required this.phone,
    required this.address,
    this.email = '',
    this.companyName = '',
  });

  // Превращаем данные ИЗ Firebase в объект Flutter
  factory ClientModel.fromMap(Map<String, dynamic> map, String documentId) {
    return ClientModel(
      id: documentId,
      companyId: map['companyId'] ?? '',
      fullName: map['fullName'] ?? '',
      phone: map['phone'] ?? '',
      address: map['address'] ?? '',
      email: map['email'] ?? '',
      companyName: map['companyName'] ?? '',
    );
  }

  // Превращаем объект Flutter обратно в формат для сохранения В Firebase
  Map<String, dynamic> toMap() {
    return {
      'companyId': companyId,
      'fullName': fullName,
      'phone': phone,
      'address': address,
      'email': email,
      'companyName': companyName,
      'updatedAt': DateTime.now(), // Дата последнего изменения
    };
  }
}