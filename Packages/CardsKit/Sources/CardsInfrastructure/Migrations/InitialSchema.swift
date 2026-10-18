import GRDB

/// Version 1 is immutable after delivery. Evolve persisted databases with a new migration.
enum InitialSchema {
    static func create(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE collection_meta (
                id TEXT PRIMARY KEY NOT NULL,
                singleton INTEGER NOT NULL DEFAULT 1 UNIQUE CHECK (singleton = 1),
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                containerVersion INTEGER NOT NULL CHECK (containerVersion > 0),
                schemaVersion INTEGER NOT NULL CHECK (schemaVersion > 0),
                createdAt INTEGER NOT NULL,
                settingsRevision INTEGER NOT NULL DEFAULT 0 CHECK (settingsRevision >= 0)
            ) STRICT;
            CREATE TRIGGER collection_meta_keep_row BEFORE DELETE ON collection_meta
            BEGIN SELECT RAISE(ABORT, 'collection metadata cannot be deleted'); END;
            CREATE TRIGGER collection_meta_keep_identity BEFORE UPDATE OF id ON collection_meta
            WHEN NEW.id != OLD.id
            BEGIN SELECT RAISE(ABORT, 'collection identity is immutable'); END;
            CREATE TRIGGER collection_meta_no_replace BEFORE INSERT ON collection_meta
            WHEN EXISTS (SELECT 1 FROM collection_meta)
            BEGIN SELECT RAISE(ABORT, 'collection metadata already exists'); END;

            CREATE TABLE scheduler_parameters (
                id TEXT PRIMARY KEY NOT NULL,
                algorithmVersion TEXT NOT NULL,
                weightsJSON TEXT NOT NULL CHECK (json_valid(weightsJSON) AND
                    json_type(weightsJSON, '$.schemaVersion') IS 'integer' AND json_extract(weightsJSON, '$.schemaVersion') > 0),
                desiredRetention REAL NOT NULL CHECK (desiredRetention > 0 AND desiredRetention < 1),
                maximumIntervalDays INTEGER NOT NULL CHECK (maximumIntervalDays > 0),
                learningPolicyJSON TEXT NOT NULL CHECK (json_valid(learningPolicyJSON) AND
                    json_type(learningPolicyJSON, '$.schemaVersion') IS 'integer' AND json_extract(learningPolicyJSON, '$.schemaVersion') > 0),
                createdAt INTEGER NOT NULL
            ) STRICT;
            CREATE TRIGGER scheduler_parameters_immutable BEFORE UPDATE ON scheduler_parameters
            BEGIN SELECT RAISE(ABORT, 'create a new parameter set'); END;
            CREATE TRIGGER scheduler_parameters_no_replace BEFORE INSERT ON scheduler_parameters
            WHEN EXISTS (SELECT 1 FROM scheduler_parameters WHERE id = NEW.id)
            BEGIN SELECT RAISE(ABORT, 'create a new parameter set'); END;
            CREATE TABLE deck_presets (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                newLimit INTEGER NOT NULL CHECK (newLimit >= 0),
                reviewLimit INTEGER NOT NULL CHECK (reviewLimit >= 0),
                schedulerParameterSetID TEXT NOT NULL REFERENCES scheduler_parameters(id),
                orderPolicyJSON TEXT NOT NULL CHECK (json_valid(orderPolicyJSON) AND
                    json_type(orderPolicyJSON, '$.schemaVersion') IS 'integer' AND json_extract(orderPolicyJSON, '$.schemaVersion') > 0),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0)
            ) STRICT;
            CREATE INDEX deck_presets_parameters ON deck_presets(schedulerParameterSetID);
            CREATE TABLE decks (
                id TEXT PRIMARY KEY NOT NULL CHECK (length(id) > 0),
                parentID TEXT REFERENCES decks(id),
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                normalizedName TEXT NOT NULL CHECK (length(trim(normalizedName)) > 0),
                description TEXT NOT NULL DEFAULT '',
                iconKey TEXT NOT NULL DEFAULT 'rectangle.stack',
                colorKey TEXT NOT NULL DEFAULT 'accent',
                favorite INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0, 1)),
                sortOrder INTEGER NOT NULL DEFAULT 0,
                presetID TEXT REFERENCES deck_presets(id),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                deletedAt INTEGER,
                CHECK (parentID IS NULL OR parentID != id)
            ) STRICT;
            CREATE UNIQUE INDEX decks_active_sibling_name
                ON decks(coalesce(parentID, ''), normalizedName) WHERE deletedAt IS NULL;
            CREATE INDEX decks_parent ON decks(parentID);
            CREATE INDEX decks_preset ON decks(presetID);
            CREATE TRIGGER decks_no_cycle BEFORE UPDATE OF parentID ON decks
            WHEN NEW.parentID IS NOT NULL
            BEGIN
                SELECT RAISE(ABORT, 'deck hierarchy cycle') WHERE NEW.id IN (
                    WITH RECURSIVE ancestors(id) AS (
                        SELECT NEW.parentID UNION
                        SELECT decks.parentID FROM decks JOIN ancestors ON decks.id = ancestors.id
                        WHERE decks.parentID IS NOT NULL
                    ) SELECT id FROM ancestors
                );
            END;
            CREATE TRIGGER decks_no_insert_cycle BEFORE INSERT ON decks
            WHEN NEW.parentID IS NOT NULL
            BEGIN
                SELECT RAISE(ABORT, 'deck hierarchy cycle') WHERE NEW.id IN (
                    WITH RECURSIVE ancestors(id) AS (
                        SELECT NEW.parentID UNION
                        SELECT decks.parentID FROM decks JOIN ancestors ON decks.id = ancestors.id
                        WHERE decks.parentID IS NOT NULL
                    ) SELECT id FROM ancestors
                );
            END;

            CREATE TABLE note_types (
                id TEXT PRIMARY KEY NOT NULL,
                stableKey TEXT NOT NULL UNIQUE CHECK (length(stableKey) > 0),
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                version INTEGER NOT NULL CHECK (version > 0),
                fieldsSchemaJSON TEXT NOT NULL CHECK (json_valid(fieldsSchemaJSON) AND
                    json_type(fieldsSchemaJSON, '$.schemaVersion') IS 'integer' AND json_extract(fieldsSchemaJSON, '$.schemaVersion') > 0),
                templatesJSON TEXT NOT NULL CHECK (json_valid(templatesJSON) AND
                    json_type(templatesJSON, '$.schemaVersion') IS 'integer' AND json_extract(templatesJSON, '$.schemaVersion') > 0),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                deletedAt INTEGER
            ) STRICT;
            CREATE TABLE notes (
                id TEXT PRIMARY KEY NOT NULL,
                noteTypeID TEXT NOT NULL REFERENCES note_types(id),
                fieldsJSON TEXT NOT NULL CHECK (json_valid(fieldsJSON) AND
                    json_type(fieldsJSON, '$.schemaVersion') IS 'integer' AND json_extract(fieldsJSON, '$.schemaVersion') > 0),
                contentVersion INTEGER NOT NULL CHECK (contentVersion > 0),
                normalizedFront TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                deletedAt INTEGER
            ) STRICT;
            CREATE INDEX notes_type ON notes(noteTypeID);
            CREATE TABLE cards (
                id TEXT PRIMARY KEY NOT NULL,
                noteID TEXT NOT NULL REFERENCES notes(id),
                deckID TEXT NOT NULL REFERENCES decks(id),
                variantKey TEXT NOT NULL CHECK (length(variantKey) > 0),
                templateID TEXT NOT NULL CHECK (length(templateID) > 0),
                clozeIndex INTEGER CHECK (clozeIndex IS NULL OR clozeIndex > 0),
                generationState TEXT NOT NULL DEFAULT 'active'
                    CHECK (generationState IN ('active', 'suppressed', 'orphaned')),
                suspended INTEGER NOT NULL DEFAULT 0 CHECK (suspended IN (0, 1)),
                buriedUntil INTEGER,
                flag INTEGER NOT NULL DEFAULT 0 CHECK (flag BETWEEN 0 AND 7),
                createdAt INTEGER NOT NULL,
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                deletedAt INTEGER,
                UNIQUE(noteID, variantKey)
            ) STRICT;
            CREATE INDEX cards_deck_availability ON cards(deckID, deletedAt, suspended);
            CREATE TABLE card_schedules (
                cardID TEXT PRIMARY KEY NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                algorithmID TEXT NOT NULL,
                algorithmVersion TEXT NOT NULL,
                parameterSetID TEXT NOT NULL REFERENCES scheduler_parameters(id),
                phase TEXT NOT NULL CHECK (phase IN ('new', 'learning', 'review', 'relearning')),
                stability REAL CHECK (stability IS NULL OR (stability > 0 AND stability <= 1.7976931348623157e308)),
                difficulty REAL CHECK (difficulty IS NULL OR difficulty BETWEEN 1 AND 10),
                dueAt INTEGER,
                lastReviewAt INTEGER,
                repetitions INTEGER NOT NULL DEFAULT 0 CHECK (repetitions >= 0),
                lapses INTEGER NOT NULL DEFAULT 0 CHECK (lapses >= 0),
                learningStep INTEGER CHECK (learningStep IS NULL OR learningStep >= 0),
                scheduleEpoch INTEGER NOT NULL DEFAULT 0 CHECK (scheduleEpoch >= 0),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0)
            ) STRICT;
            CREATE INDEX card_schedules_due_phase ON card_schedules(dueAt, phase);
            CREATE INDEX card_schedules_parameters ON card_schedules(parameterSetID);
            CREATE TABLE tags (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL CHECK (length(trim(name)) > 0),
                normalizedName TEXT NOT NULL CHECK (length(trim(normalizedName)) > 0),
                color TEXT NOT NULL DEFAULT 'accent',
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0),
                deletedAt INTEGER
            ) STRICT;
            CREATE UNIQUE INDEX tags_active_name ON tags(normalizedName) WHERE deletedAt IS NULL;
            CREATE TABLE note_tags (
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                tagID TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                PRIMARY KEY(noteID, tagID)
            ) STRICT;
            CREATE INDEX note_tags_tag ON note_tags(tagID);
            CREATE TABLE media_assets (
                id TEXT PRIMARY KEY NOT NULL,
                sha256 TEXT NOT NULL UNIQUE CHECK (length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
                relativePath TEXT NOT NULL UNIQUE CHECK (
                    relativePath GLOB 'Media/?*' AND substr(relativePath, 7) NOT GLOB '*[/:\\]*'
                    AND substr(relativePath, 7) NOT IN ('.', '..') AND instr(relativePath, char(0)) = 0),
                uti TEXT NOT NULL CHECK (length(uti) > 0),
                byteCount INTEGER NOT NULL CHECK (byteCount >= 0),
                createdAt INTEGER NOT NULL,
                lifecycleState TEXT NOT NULL CHECK (lifecycleState IN ('published', 'orphaned', 'trashed'))
            ) STRICT;
            CREATE TABLE note_media (
                noteID TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                mediaID TEXT NOT NULL REFERENCES media_assets(id),
                fieldID TEXT NOT NULL CHECK (length(fieldID) > 0),
                role TEXT NOT NULL CHECK (length(role) > 0),
                orderIndex INTEGER NOT NULL CHECK (orderIndex >= 0),
                PRIMARY KEY(noteID, fieldID, role, orderIndex)
            ) STRICT;
            CREATE INDEX note_media_asset ON note_media(mediaID);

            CREATE TABLE study_sessions (
                id TEXT PRIMARY KEY NOT NULL,
                mode TEXT NOT NULL CHECK (mode IN ('scheduled', 'practice')),
                scopeJSON TEXT NOT NULL CHECK (json_valid(scopeJSON) AND
                    json_type(scopeJSON, '$.schemaVersion') IS 'integer' AND json_extract(scopeJSON, '$.schemaVersion') > 0),
                startedAt INTEGER NOT NULL,
                lastActivityAt INTEGER NOT NULL,
                endedAt INTEGER,
                status TEXT NOT NULL CHECK (status IN ('active', 'paused', 'completed', 'abandoned')),
                activeDurationMs INTEGER NOT NULL DEFAULT 0 CHECK (activeDurationMs >= 0),
                studyPolicyJSON TEXT NOT NULL CHECK (json_valid(studyPolicyJSON) AND
                    json_type(studyPolicyJSON, '$.schemaVersion') IS 'integer' AND json_extract(studyPolicyJSON, '$.schemaVersion') > 0),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0)
            ) STRICT;
            CREATE UNIQUE INDEX study_sessions_one_scheduled ON study_sessions(mode)
                WHERE mode = 'scheduled' AND status IN ('active', 'paused');
            CREATE TABLE session_items (
                id TEXT PRIMARY KEY NOT NULL,
                sessionID TEXT NOT NULL REFERENCES study_sessions(id) ON DELETE CASCADE,
                cardID TEXT NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
                queueOrdinal INTEGER NOT NULL CHECK (queueOrdinal >= 0),
                stage TEXT NOT NULL CHECK (stage IN ('queued', 'question', 'answer', 'rated', 'skipped')),
                eligibleAt INTEGER,
                presentedAt INTEGER,
                typedDraft TEXT,
                generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
                UNIQUE(sessionID, queueOrdinal)
            ) STRICT;
            CREATE INDEX session_items_queue ON session_items(sessionID, stage, queueOrdinal);
            CREATE INDEX session_items_card ON session_items(cardID);
            CREATE TABLE review_logs (
                id TEXT PRIMARY KEY NOT NULL,
                commandID TEXT NOT NULL UNIQUE,
                cardID TEXT REFERENCES cards(id) ON DELETE SET NULL,
                cardIdentitySnapshot TEXT NOT NULL,
                sessionID TEXT REFERENCES study_sessions(id) ON DELETE SET NULL,
                ratedAt INTEGER NOT NULL,
                studyDayKey TEXT NOT NULL,
                timezoneID TEXT NOT NULL,
                deckIDSnapshot TEXT NOT NULL,
                grade INTEGER NOT NULL CHECK (grade BETWEEN 1 AND 4),
                phaseBefore TEXT NOT NULL CHECK (phaseBefore IN ('new', 'learning', 'review', 'relearning')),
                durationMs INTEGER NOT NULL CHECK (durationMs >= 0),
                beforeJSON TEXT NOT NULL CHECK (json_valid(beforeJSON) AND
                    json_type(beforeJSON, '$.schemaVersion') IS 'integer' AND json_extract(beforeJSON, '$.schemaVersion') > 0),
                afterJSON TEXT NOT NULL CHECK (json_valid(afterJSON) AND
                    json_type(afterJSON, '$.schemaVersion') IS 'integer' AND json_extract(afterJSON, '$.schemaVersion') > 0),
                parameterSetID TEXT NOT NULL REFERENCES scheduler_parameters(id),
                scheduleEpoch INTEGER NOT NULL CHECK (scheduleEpoch >= 0),
                voidedBy TEXT
            ) STRICT;
            CREATE INDEX review_logs_day_deck_effective ON review_logs(studyDayKey, deckIDSnapshot, voidedBy);
            CREATE INDEX review_logs_card ON review_logs(cardID);
            CREATE INDEX review_logs_session ON review_logs(sessionID);
            CREATE INDEX review_logs_parameters ON review_logs(parameterSetID);
            CREATE TABLE domain_events (
                id TEXT PRIMARY KEY NOT NULL,
                commandID TEXT NOT NULL,
                type TEXT NOT NULL,
                objectID TEXT NOT NULL,
                occurredAt INTEGER NOT NULL,
                payloadVersion INTEGER NOT NULL CHECK (payloadVersion > 0),
                payloadJSON TEXT NOT NULL CHECK (json_valid(payloadJSON) AND
                    json_type(payloadJSON, '$.schemaVersion') IS 'integer' AND json_extract(payloadJSON, '$.schemaVersion') > 0)
            ) STRICT;
            CREATE INDEX domain_events_command ON domain_events(commandID);
            CREATE TABLE processed_commands (
                commandID TEXT PRIMARY KEY NOT NULL,
                resultVersion INTEGER NOT NULL CHECK (resultVersion > 0),
                resultJSON TEXT NOT NULL CHECK (json_valid(resultJSON) AND
                    json_type(resultJSON, '$.schemaVersion') IS 'integer' AND json_extract(resultJSON, '$.schemaVersion') > 0),
                createdAt INTEGER NOT NULL
            ) STRICT;
            CREATE TABLE collection_settings (
                key TEXT PRIMARY KEY NOT NULL,
                valueJSON TEXT NOT NULL CHECK (json_valid(valueJSON) AND
                    json_type(valueJSON, '$.schemaVersion') IS 'integer' AND json_extract(valueJSON, '$.schemaVersion') > 0),
                revision INTEGER NOT NULL DEFAULT 0 CHECK (revision >= 0)
            ) STRICT;
            CREATE TABLE local_notifications (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                payloadJSON TEXT NOT NULL CHECK (json_valid(payloadJSON) AND
                    json_type(payloadJSON, '$.schemaVersion') IS 'integer' AND json_extract(payloadJSON, '$.schemaVersion') > 0),
                readAt INTEGER
            ) STRICT;
            CREATE TABLE operation_journal (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                phase TEXT NOT NULL,
                stagingRelativePath TEXT NOT NULL,
                manifestJSON TEXT NOT NULL CHECK (json_valid(manifestJSON) AND
                    json_type(manifestJSON, '$.schemaVersion') IS 'integer' AND json_extract(manifestJSON, '$.schemaVersion') > 0),
                startedAt INTEGER NOT NULL,
                completedAt INTEGER
            ) STRICT;
            CREATE TABLE deletion_batches (
                id TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                affectedIDsJSON TEXT NOT NULL CHECK (json_valid(affectedIDsJSON) AND
                    json_type(affectedIDsJSON, '$.schemaVersion') IS 'integer' AND json_extract(affectedIDsJSON, '$.schemaVersion') > 0),
                deletedAt INTEGER NOT NULL,
                undoUntil INTEGER,
                purgeAfter INTEGER NOT NULL,
                state TEXT NOT NULL CHECK (state IN ('pending', 'restored', 'purged')),
                CHECK (purgeAfter >= deletedAt)
            ) STRICT;
            """)
    }
}
