# Local-only project artifacts

The original project package also contains large binary/reference artifacts that are deliberately kept out of normal Git history:

| Artifact | Size | SHA-256 |
|---|---:|---|
| `GLOBAL_SIGNATURE_STRONG_V2_DEPLOYMENT.zip` | 51,993,956 bytes | `b7c9833628302fa7e3c58e14aa7d353db3267518a90c48907ce17b244f53d861` |
| `bandicam 2026-07-31 20-37-15-672.mp4` | 27,830,365 bytes | `dedbbdb31c4560926af09d5cc4378a2cab041bdba8437a2e7082662cbbed2f8d` |
| `SignaTrust_Application_Implementation.docx` | 8,787,451 bytes | `c19672bb3fbefb844b64e383c3aff25f29618bba3babb4271346ebfabf0d8303` |

The source code, training pipeline, model metadata/configuration, and runtime integration are version-controlled. Large model/media deliverables should be distributed via Git LFS or a release/package store.
