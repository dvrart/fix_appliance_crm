/**
 * Автоматическая синхронизация изменений из основного приложения
 * (`C:\Projects\fix_appliance_crm`) в копию для тестировщиков
 * (`C:\Projects\fix_appliance_testers`).
 *
 * Запускается автоматически при каждом git commit (.git/hooks/post-commit),
 * а также может быть вызвана вручную: `node tools/sync_testers.js`.
 */
const fs = require('node:fs');
const path = require('node:path');

const SRC_ROOT = path.resolve(__dirname, '..');
const DST_ROOT = path.resolve(SRC_ROOT, '..', 'fix_appliance_testers');

function copyRecursive(src, dst, shouldSkip) {
  if (!fs.existsSync(src)) return;
  if (shouldSkip && shouldSkip(src)) return;
  const stat = fs.statSync(src);
  if (stat.isDirectory()) {
    fs.mkdirSync(dst, { recursive: true });
    for (const entry of fs.readdirSync(src)) {
      copyRecursive(path.join(src, entry), path.join(dst, entry), shouldSkip);
    }
    return;
  }
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
}

function main() {
  if (!fs.existsSync(DST_ROOT)) {
    console.log('sync_testers: папка тестировщиков не найдена:', DST_ROOT);
    return;
  }

  // 1. Синхронизируем общие директории кода, ассетов, тестов и нативных классов
  const dirsToSync = [
    'lib',
    'assets',
    'test',
    'third_party',
    path.join('hosting', 'public', 'tech'),
    path.join('android', 'app', 'src', 'main', 'kotlin'),
    path.join('android', 'app', 'src', 'test', 'kotlin'),
  ];

  for (const rel of dirsToSync) {
    copyRecursive(path.join(SRC_ROOT, rel), path.join(DST_ROOT, rel));
  }

  // 2. Синхронизируем корневые файлы конфигурации и правил
  const filesToSync = [
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    'firestore.rules',
    'storage.rules',
  ];

  for (const rel of filesToSync) {
    const s = path.join(SRC_ROOT, rel);
    const d = path.join(DST_ROOT, rel);
    if (fs.existsSync(s)) fs.copyFileSync(s, d);
  }

  // 3. В тестовой копии включаем флаг kTesterAppBuild = true по умолчанию
  const testerBuildPath = path.join(DST_ROOT, 'lib', 'core', 'tester_build.dart');
  fs.writeFileSync(
    testerBuildPath,
    `/// Сборка для внешних тестировщиков (\`C:\\Projects\\fix_appliance_testers\`).
const bool kTesterAppBuild = bool.fromEnvironment(
  'TESTER_APP',
  defaultValue: true,
);
`,
    'utf8'
  );

  // 4. В тестовой копии очищаем логин/пароль владельца в api_keys.dart
  const apiKeysPath = path.join(DST_ROOT, 'lib', 'core', 'api_keys.dart');
  if (fs.existsSync(apiKeysPath)) {
    let content = fs.readFileSync(apiKeysPath, 'utf8');
    content = content
      .replace(/const String kOwnerEmail\s*=\s*'[^']*';/, "const String kOwnerEmail = '';")
      .replace(/const String kOwnerPassword\s*=\s*'[^']*';/, "const String kOwnerPassword = '';");
    fs.writeFileSync(apiKeysPath, content, 'utf8');
  }

  // 5. В тестовой копии привязываем Android appId пакета com.example.fix_appliance_crm
  const fbOptsPath = path.join(DST_ROOT, 'lib', 'firebase_options.dart');
  if (fs.existsSync(fbOptsPath)) {
    let fb = fs.readFileSync(fbOptsPath, 'utf8');
    fb = fb.replace(
      "appId: '1:772324431093:android:1bab4004783335bd2fe1bc'",
      "appId: '1:772324431093:android:afff73faed16a00f2fe1bc'"
    );
    fs.writeFileSync(fbOptsPath, fb, 'utf8');
  }

  console.log('sync_testers: изменения синхронизированы в', DST_ROOT);
}

main();
