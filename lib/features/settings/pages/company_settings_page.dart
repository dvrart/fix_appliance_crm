import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants.dart';
import '../../../services/settings_service.dart';
import '../widgets/company_logo.dart';
import '../widgets/company_name_dialog.dart';
import '../widgets/settings_ui.dart';
import '../../../core/l10n/app_locale.dart';

class CompanySettingsPage extends StatefulWidget {
  const CompanySettingsPage({super.key});

  @override
  State<CompanySettingsPage> createState() => _CompanySettingsPageState();
}

class _CompanySettingsPageState extends State<CompanySettingsPage> {
  bool _loading = true;
  bool _uploading = false;
  String _name = 'Fix Appliance';
  String _phone = '';
  String _email = '';
  String _address = '';
  String _logoUrl = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await SettingsService.loadDocumentSettings(force: true);
    if (!mounted) return;
    setState(() {
      _name = docs.companyName;
      _phone = docs.companyPhone;
      _email = docs.companyEmail;
      _address = docs.companyAddress;
      _logoUrl = docs.logoUrl;
      _loading = false;
    });
  }

  Future<void> _editName() async {
    final saved = await showCompanyNameDialog(
      context: context,
      initialName: _name,
    );
    if (saved == null || saved.isEmpty || !mounted) return;
    await SettingsService.updateCompanyName(saved);
    if (!mounted) return;
    setState(() => _name = saved);
  }

  Future<void> _editPhone() async {
    final saved = await showCompanyPhoneDialog(
      context: context,
      initialValue: _phone,
    );
    if (saved == null || !mounted) return;
    await SettingsService.updateCompanyPhone(saved);
    if (!mounted) return;
    setState(() => _phone = saved);
  }

  Future<void> _editEmail() async {
    final saved = await showCompanyEmailDialog(
      context: context,
      initialValue: _email,
    );
    if (saved == null || !mounted) return;
    await SettingsService.updateCompanyEmail(saved);
    if (!mounted) return;
    setState(() => _email = saved);
  }

  Future<void> _editAddress() async {
    final saved = await showCompanyAddressDialog(
      context: context,
      initialValue: _address,
    );
    if (saved == null || !mounted) return;
    await SettingsService.updateCompanyAddress(saved);
    if (!mounted) return;
    setState(() => _address = saved);
  }

  Future<void> _changeLogo() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1024,
    );
    if (picked == null || !mounted) return;

    setState(() => _uploading = true);
    try {
      final ref = FirebaseStorage.instance
          .ref()
          .child('companies')
          .child(kCompanyId)
          .child('branding')
          .child('logo.jpg');
      await ref.putFile(File(picked.path));
      final url = await ref.getDownloadURL();
      final current = await SettingsService.loadDocumentSettings();
      await SettingsService.saveDocumentSettings(current.copyWith(logoUrl: url));
      if (!mounted) return;
      setState(() => _logoUrl = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${'Не удалось сохранить логотип'.tr}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Компания'.tr,
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
                          CompanyLogo(url: _logoUrl, size: 108, onTap: _changeLogo),
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
                const SizedBox(height: 24),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      title: 'Название компании'.tr,
                      subtitle: _name,
                      icon: Icons.business,
                      iconColor: AppColors.primary,
                      onTap: _editName,
                    ),
                    SettingsRow(
                      title: 'Телефон'.tr,
                      subtitle: _phone.isEmpty ? 'Не указан'.tr : _phone,
                      icon: Icons.phone,
                      iconColor: Colors.teal,
                      onTap: _editPhone,
                    ),
                    SettingsRow(
                      title: 'Email',
                      subtitle: _email.isEmpty ? 'Не указан'.tr : _email,
                      icon: Icons.email_outlined,
                      iconColor: Colors.indigo,
                      onTap: _editEmail,
                    ),
                    SettingsRow(
                      title: 'Адрес'.tr,
                      subtitle: _address.isEmpty ? 'Не указан'.tr : _address,
                      icon: Icons.location_on,
                      iconColor: Colors.orange,
                      showDivider: false,
                      onTap: _editAddress,
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
