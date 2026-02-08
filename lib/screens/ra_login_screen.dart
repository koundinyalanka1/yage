import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/retro_achievements_service.dart';
import '../utils/theme.dart';

/// Screen for logging into RetroAchievements with username + API key.
class RALoginScreen extends StatefulWidget {
  const RALoginScreen({super.key});

  @override
  State<RALoginScreen> createState() => _RALoginScreenState();
}

class _RALoginScreenState extends State<RALoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _apiKeyController = TextEditingController();

  bool _obscureApiKey = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _usernameController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final raService = context.read<RetroAchievementsService>();
    final result = await raService.login(
      _usernameController.text,
      _apiKeyController.text,
    );

    if (!mounted) return;

    if (result.success) {
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Welcome, ${result.profile?.username ?? 'Player'}!',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      setState(() {
        _isSubmitting = false;
        _errorMessage = result.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('RetroAchievements'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header / logo area ──
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [YageColors.primary, YageColors.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: YageColors.primary.withAlpha(80),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.emoji_events,
                      size: 36,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'RetroAchievements Login',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: YageColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Enter your RetroAchievements username and\nWeb API key to unlock achievements.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: YageColors.textSecondary,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),

              // ── Username field ──
              TextFormField(
                controller: _usernameController,
                enabled: !_isSubmitting,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: 'Username',
                  hintText: 'Your RetroAchievements username',
                  prefixIcon: Icon(
                    Icons.person_outline,
                    color: YageColors.accent,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Username is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ── API key field ──
              TextFormField(
                controller: _apiKeyController,
                enabled: !_isSubmitting,
                obscureText: _obscureApiKey,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Web API Key',
                  hintText: 'Paste your API key here',
                  prefixIcon: Icon(
                    Icons.key,
                    color: YageColors.accent,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureApiKey
                          ? Icons.visibility_off
                          : Icons.visibility,
                      color: YageColors.textMuted,
                    ),
                    onPressed: () {
                      setState(() => _obscureApiKey = !_obscureApiKey);
                    },
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'API key is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),

              // ── Helper text ──
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: YageColors.backgroundLight,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: YageColors.surfaceLight,
                    width: 1,
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: YageColors.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Find your Web API Key at:\n'
                        'retroachievements.org → Settings → Keys\n\n'
                        'This is NOT your password.',
                        style: TextStyle(
                          fontSize: 12,
                          color: YageColors.textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── Error message ──
              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: YageColors.error.withAlpha(25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: YageColors.error.withAlpha(80),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 20,
                        color: YageColors.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            fontSize: 13,
                            color: YageColors.error,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ── Submit button ──
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: YageColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: YageColors.primary.withAlpha(100),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _isSubmitting
                      ? SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: YageColors.textPrimary,
                          ),
                        )
                      : const Text(
                          'Sign In',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
