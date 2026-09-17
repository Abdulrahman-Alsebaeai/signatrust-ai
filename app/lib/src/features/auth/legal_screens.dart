import 'package:flutter/material.dart';

class TermsOfUseScreen extends StatelessWidget {
  const TermsOfUseScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalDocumentScreen(
        title: 'Terms of Use',
        sections: [
          _LegalSection(
            'Account use',
            'You must provide accurate account information and keep your password private. You are responsible for activity performed through your account on this device.',
          ),
          _LegalSection(
            'Signature enrollment',
            'The application stores five encrypted behavioral signature references locally. You must enroll only your own signature and use the application for lawful purposes.',
          ),
          _LegalSection(
            'Electronic signing',
            'A document is marked as electronically signed only after a newly captured signature is accepted by the local verification model. The signed preview records the decision, confidence, and signing time.',
          ),
          _LegalSection(
            'Local operation',
            'Accounts, documents, signature references, and administrator review are stored on this device. Removing application data or uninstalling the application may permanently remove local records.',
          ),
          _LegalSection(
            'Responsible use',
            'Do not use the application to impersonate another person, forge a signature, or sign a document without proper authority.',
          ),
        ],
      );
}

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) => const _LegalDocumentScreen(
        title: 'Privacy Policy',
        sections: [
          _LegalSection(
            'Information stored',
            'The application stores your name, email address, optional phone number, encrypted password data, encrypted signature references, verification records, and encrypted documents.',
          ),
          _LegalSection(
            'Behavioral signature data',
            'During signing, the application captures coordinates, timing, pressure when available, touch area, pointer type, speed-related movement, and stroke behavior for local analysis.',
          ),
          _LegalSection(
            'How data is used',
            'Data is used to create your signature reference, verify newly submitted signatures, sign selected documents, display history, and support local administrator review when you explicitly share a signed document.',
          ),
          _LegalSection(
            'Storage and sharing',
            'Data remains inside the application storage on this device. A signed document becomes visible to the local administrator only after you enable sharing for that document.',
          ),
          _LegalSection(
            'Your control',
            'You can update profile information, replace signature enrollment, stop sharing a document, delete a document, or sign out. Deleting a document removes its encrypted original and generated signed files from application storage.',
          ),
        ],
      );
}

class _LegalDocumentScreen extends StatelessWidget {
  final String title;
  final List<_LegalSection> sections;

  const _LegalDocumentScreen({
    required this.title,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 32),
            itemCount: sections.length,
            separatorBuilder: (_, __) => const SizedBox(height: 22),
            itemBuilder: (context, index) {
              final section = sections[index];
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    section.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    section.body,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              );
            },
          ),
        ),
      );
}

class _LegalSection {
  final String title;
  final String body;

  const _LegalSection(this.title, this.body);
}
