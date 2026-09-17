import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

class LocalDatabase {
  LocalDatabase._();

  static final instance = LocalDatabase._();

  Database? _database;

  Database get database {
    final db = _database;
    if (db == null) {
      throw StateError('Local database has not been initialized.');
    }
    return db;
  }

  Future<void> initialize() async {
    if (_database != null) return;

    final databasesPath = await getDatabasesPath();
    final databasePath = path.join(databasesPath, 'signatrust_local.db');

    _database = await openDatabase(
      databasePath,
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            email TEXT NOT NULL UNIQUE COLLATE NOCASE,
            full_name TEXT NOT NULL,
            phone TEXT,
            avatar_url TEXT,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user',
            is_active INTEGER NOT NULL DEFAULT 1,
            accepted_terms_at TEXT,
            accepted_privacy_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE enrollment_templates (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL UNIQUE,
            encrypted_sequences BLOB NOT NULL,
            reference_count INTEGER NOT NULL DEFAULT 5,
            quality_score REAL NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE verification_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            mode TEXT NOT NULL,
            score REAL NOT NULL,
            calibrated_logit REAL NOT NULL,
            cosine_similarity REAL NOT NULL,
            threshold_value REAL NOT NULL,
            decision TEXT NOT NULL,
            quality_score REAL NOT NULL DEFAULT 0,
            request_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            owner_id INTEGER NOT NULL,
            original_name TEXT NOT NULL,
            stored_name TEXT NOT NULL UNIQUE,
            mime_type TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            encrypted_path TEXT NOT NULL,
            is_shared_with_admin INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'uploaded',
            signed_preview_path TEXT,
            signature_path TEXT,
            signed_at TEXT,
            signature_verification_id INTEGER,
            signature_probability REAL,
            signature_decision TEXT,
            created_at TEXT NOT NULL,
            FOREIGN KEY(owner_id) REFERENCES users(id) ON DELETE CASCADE,
            FOREIGN KEY(signature_verification_id)
              REFERENCES verification_events(id) ON DELETE SET NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            actor_user_id INTEGER,
            action TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            resource_id TEXT,
            details_json TEXT NOT NULL DEFAULT '{}',
            created_at TEXT NOT NULL,
            FOREIGN KEY(actor_user_id) REFERENCES users(id) ON DELETE SET NULL
          )
        ''');

        await _createIndexes(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE users ADD COLUMN accepted_terms_at TEXT');
          await db.execute('ALTER TABLE users ADD COLUMN accepted_privacy_at TEXT');
          await db.execute(
            'ALTER TABLE documents ADD COLUMN signed_preview_path TEXT',
          );
          await db.execute(
            'ALTER TABLE documents ADD COLUMN signature_path TEXT',
          );
          await db.execute('ALTER TABLE documents ADD COLUMN signed_at TEXT');
          await db.execute(
            'ALTER TABLE documents ADD COLUMN signature_verification_id INTEGER',
          );
          await db.execute(
            'ALTER TABLE documents ADD COLUMN signature_probability REAL',
          );
          await db.execute(
            'ALTER TABLE documents ADD COLUMN signature_decision TEXT',
          );
          await db.execute('''
            UPDATE documents
            SET status = 'uploaded'
            WHERE signed_at IS NULL
          ''');
          await _createIndexes(db);
        }
      },
    );
  }

  static Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_verification_user_created '
      'ON verification_events(user_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_owner_created '
      'ON documents(owner_id, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_documents_shared_created '
      'ON documents(is_shared_with_admin, created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_audit_created '
      'ON audit_logs(created_at DESC)',
    );
  }
}
