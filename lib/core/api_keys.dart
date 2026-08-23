/// Ключ Gemini для ассистента в шапке.
/// Если пустой — смайлик всё равно слушает, но текст не разбирает.
const String kGeminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: 'YOUR_GEMINI_API_KEY',
);

const String kFirebaseFunctionsUrl = String.fromEnvironment(
  'FIREBASE_FUNCTIONS_URL',
  defaultValue: 'https://us-central1-fix-appliance-crm.cloudfunctions.net',
);
