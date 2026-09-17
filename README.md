# SignaTrust AI

**AI-assisted digital signature verification platform built with Flutter and an offline-capable signature-verification pipeline.**

SignaTrust AI combines a production-style mobile application with a trained signature-verification model pipeline. The application includes authentication, document workflows, signature capture/verification, history, profile/admin areas, local encrypted storage, local database services, signature preprocessing, and on-device model integration.

## Highlights

- Flutter mobile application with Riverpod state management and `go_router` navigation.
- Local-first storage and encrypted application data.
- Signature preprocessing and local inference service integration.
- Training pipeline for global online-signature verification using public datasets.
- Export workflow for TorchScript / ONNX deployment artifacts.
- Separate model metadata, configuration, training manifest, and inference example.
- Portfolio-ready project documentation and UI reference screenshots.

## Repository structure

```text
app/            Flutter application
training/       Signature-model training pipeline
model_bundle/   Deployment metadata and model inventory
docs/           Training notes, checksums, and UI references
```

## Application setup

Requirements: Flutter 3.x / Dart 3.x and an Android toolchain.

```bash
cd app
flutter pub get
flutter run
```

The production model archive is intentionally kept out of normal Git history. Place `GLOBAL_SIGNATURE_STRONG_V2_DEPLOYMENT.zip` under `app/assets/model_bundle/` before running the local model service. The exact artifact inventory and SHA-256 checksums are recorded in [`model_bundle/MODEL_ARTIFACTS.md`](model_bundle/MODEL_ARTIFACTS.md).

## Training

The training entry point is [`training/training_code.py`](training/training_code.py). It includes dataset acquisition/scanning, preprocessing, representation learning, verification training, evaluation, threshold selection, and deployment export.

## Security and repository hygiene

Generated build folders, local SDK paths, caches, IDE metadata, and large binary deliverables are excluded from Git. See [`.gitignore`](.gitignore) and [`docs/LOCAL_ARTIFACTS.md`](docs/LOCAL_ARTIFACTS.md).

## Status

Academic / portfolio implementation. Review deployment, model licensing, privacy requirements, and production threat models before real-world use.
