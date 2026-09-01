import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

/// Базовый сервис для Firestore — единая точка доступа к коллекциям
class FirestoreService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Корневая ссылка на компанию
  static DocumentReference get companyRef =>
      _db.collection('companies').doc(kCompanyId);

  /// Коллекция клиентов
  static CollectionReference get clientsRef =>
      companyRef.collection('clients');

  /// Коллекция заявок
  static CollectionReference get jobsRef =>
      companyRef.collection('jobs');

  /// Коллекция склада
  static CollectionReference get warehouseRef =>
      companyRef.collection('warehouse');

  /// Коллекция звонков (Twilio Voice)
  static CollectionReference get callsRef =>
      companyRef.collection('calls');

  /// Коллекция SMS-сообщений (Twilio Messaging)
  static CollectionReference get messagesRef =>
      companyRef.collection('messages');

  /// FCM-токены устройств мастера — для push о входящих SMS
  static CollectionReference get fcmTokensRef =>
      companyRef.collection('fcm_tokens');

  /// Коллекция настроек
  static CollectionReference get settingsRef =>
      companyRef.collection('settings');

  /// Документ конфигурации
  static DocumentReference get configRef =>
      settingsRef.doc('config');

  /// Документ SMS-шаблонов
  static DocumentReference get smsTemplatesRef =>
      settingsRef.doc('sms_templates');

  /// Реквизиты компании и шаблоны счетов / смет
  static DocumentReference get documentSettingsRef =>
      settingsRef.doc('documents');

  /// Скрипт ИИ-диспетчера на входящих звонках
  static DocumentReference get aiVoiceRef =>
      settingsRef.doc('ai_voice');

  /// Предложения секретаря, чему научиться (только после подтверждения мастера).
  static CollectionReference get secretaryLessonsRef =>
      companyRef.collection('secretary_lessons');

  /// Чат хозяина с секретарём — переписывают, как вести звонки.
  static CollectionReference get secretaryCoachRef =>
      companyRef.collection('secretary_coach');

  static CollectionReference get expensesRef =>
      companyRef.collection('expenses');

  static CollectionReference get calendarEventsRef =>
      companyRef.collection('calendar_events');

  /// Сообщения заявки
  static CollectionReference jobMessagesRef(String jobId) =>
      jobsRef.doc(jobId).collection('messages');
}
