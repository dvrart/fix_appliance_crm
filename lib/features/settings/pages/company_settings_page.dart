import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../models/document_settings.dart';
import '../../../services/settings_service.dart';
import '../widgets/company_logo.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';

class CompanySettingsPage extends StatefulWidget {
  const CompanySettingsPage({super.key});

  @override
  State<CompanySettingsPage> createState() => _CompanySettingsPageState();
}

class _CompanySettingsPageState extends State<CompanySettingsPage> {
  bool _loading = true;
  bool _uploading = false;
  DocumentSettings? _saved;
  String _name = 'Fix Appliance';
  String _phone = '';
  String _email = '';
  String _address = '';
  String _logoUrl = '';
  File? _pendingLogo;

  bool get _dirty {
    final saved = _saved;
    if (_loading || saved == null) return false;
    return _pendingLogo != null ||
        _name != saved.companyName ||
        _phone != saved.companyPhone ||
        _email != saved.companyEmail ||
        _address != saved.companyAddress ||
        _logoUrl != saved.logoUrl;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await SettingsService.loadDocumentSettings(force: true);
    if (!mounted) return;
    setState(() {
      _saved = docs;
      _name = docs.companyName;
      _phone = docs.companyPhone;
      _email = docs.companyEmail;
      _address = docs.companyAddress;
      _logoUrl = docs.logoUrl;
      _pendingLogo = null;
      _loading = false;
    });
  }

  Future<void> _editName() async {
    final next = await showCompanyNameDialog(
      context: context,
      initialName: _name,
    );
    if (next == null || next.isEmpty || !mounted) return;
    setState(() => _name = next);
  }

  Future<void> _editPhone() async {
    final next = await showCompanyPhoneDialog(
      context: context,
      initialValue: _phone,
    );
    if (next == null || !mounted) return;
    setState(() => _phone = next);
  }

  Future<void> _editEmail() async {
    final next = await showCompanyEmailDialog(
      context: context,
      initialValue: _email,
    );
    if (next == null || !mounted) return;
    setState(() => _email = next);
  }

  Future<void> _editAddress() async {
    final next = await showCompanyAddressDialog(
      context: context,
      initialValue: _address,
    );
    if (next == null || !mounted) return;
    setState(() => _address = next);
  }

  Future<void> _changeLogo() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
    );
    if (picked == null || !mounted) return;
    setState(() => _pendingLogo = File(picked.path));
  }

  Future<bool> _save() async {
    final current = _saved ?? await SettingsService.loadDocumentSettings();
    var logoUrl = _logoUrl;
    if (_pendingLogo != null) {
      setState(() => _uploading = true);
      try {
        final ref = FirebaseStorage.instance
            .ref()
            .child('companies')
            .child(kCompanyId)
            .child('branding')
            .child('logo.jpg');
        await ref.putFile(_pendingLogo!);
        logoUrl = await ref.getDownloadURL();
      } catch (e) {
        if (mounted) {
          setState(() => _uploading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${'Не удалось сохранить логотип'.tr}: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return false;
      }
    }

    final name = _name.trim().isEmpty
        ? DocumentSettings.defaults.companyName
        : _name.trim();
    final next = current.copyWith(
      companyName: name,
      companyPhone: _phone.trim(),
      companyEmail: _email.trim(),
      companyAddress: _address.trim(),
      logoUrl: logoUrl,
    );
    await SettingsService.saveDocumentSettings(next);
    if (!mounted) return true;
    setState(() {
      _saved = next;
      _name = next.companyName;
      _phone = next.companyPhone;
      _email = next.companyEmail;
      _address = next.companyAddress;
      _logoUrl = next.logoUrl;
      _pendingLogo = null;
      _uploading = false;
    });
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Компания'.tr,
      dirty: _dirty,
      onSave: _save,
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppColors.accent))
          : ListView(
              padding: const EdgeInsets.only(top: 20, bottom: 40),
              children: [
                Center(
                  child: Column(
                    children: [
                      Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CompanyLogo(
                            url: _logoUrl,
                            file: _pendingLogo,
                            size: 108,
                            onTap: _changeLogo,
                          ),
                          if (_uploading)
                            Positioned.fill(
                              child: CircularProgressIndicator(
                                color: AppColors.accent,
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: AppColors.accent,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit, size: 18),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Нажмите на логотип, чтобы заменить'.tr,
                        style: TextStyle(color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SettingsTileSection(
                  title: 'Компания'.tr,
                  tiles: [
                    SettingsHubTile(
                      title: 'Название'.tr,
                      subtitle: _name,
                      icon: Icons.business,
                      color: AppColors.primary,
                      onTap: _editName,
                    ),
                    SettingsHubTile(
                      title: 'Телефон'.tr,
                      subtitle: _phone.isEmpty ? 'Не указан'.tr : _phone,
                      icon: Icons.phone,
                      color: Colors.teal,
                      onTap: _editPhone,
                    ),
                    SettingsHubTile(
                      title: 'Email',
                      subtitle: _email.isEmpty ? 'Не указан'.tr : _email,
                      icon: Icons.email_outlined,
                      color: Colors.indigo,
                      onTap: _editEmail,
                    ),
                    SettingsHubTile(
                      title: 'Адрес'.tr,
                      subtitle: _address.isEmpty ? 'Не указан'.tr : _address,
                      icon: Icons.location_on,
                      color: Colors.orange,
                      onTap: _editAddress,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
