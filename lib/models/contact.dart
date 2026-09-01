/// Контактное лицо (владелец, арендатор, управляющий)
class Contact {
  final String id;
  final String name;
  final String phone;
  final String role; // 'owner', 'tenant', 'manager'
  final bool isPrimary;

  Contact({
    required this.id,
    required this.name,
    required this.phone,
    this.role = 'owner',
    this.isPrimary = false,
  });

  factory Contact.fromMap(Map<String, dynamic> map, [String? docId]) {
    return Contact(
      id: docId ?? map['id'] ?? '',
      name: map['name'] ?? '',
      phone: map['phone'] ?? '',
      role: map['role'] ?? 'owner',
      isPrimary: map['isPrimary'] ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id.isNotEmpty) 'id': id,
      'name': name,
      'phone': phone,
      'role': role,
      'isPrimary': isPrimary,
    };
  }

  Contact copyWith({
    String? id,
    String? name,
    String? phone,
    String? role,
    bool? isPrimary,
  }) {
    return Contact(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      isPrimary: isPrimary ?? this.isPrimary,
    );
  }

  String get roleLabel {
    switch (role) {
      case 'owner':
        return 'Владелец';
      case 'tenant':
        return 'Арендатор';
      case 'manager':
        return 'Управляющий';
      default:
        return role;
    }
  }
}
