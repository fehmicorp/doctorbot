-- ==========================================================
-- FEHMI SINGLE SIGN ON (SSO) MASTER SCHEMA
-- Version: 2026.1.1 | Mode: Production
-- ==========================================================

-- 1. EXTENSIONS & SCHEMAS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "postgis";

-- CREATE SCHEMA IF NOT EXISTS auth;
-- CREATE SCHEMA IF NOT EXISTS profile;
-- CREATE SCHEMA IF NOT EXISTS format;

-- ==========================================================
-- RECOVERY & DATA LIFECYCLE MANAGEMENT
-- ==========================================================
CREATE SCHEMA IF NOT EXISTS recovery;

-- 1. DELETED DATA (Temporary 90-day storage)
CREATE TABLE IF NOT EXISTS recovery.delete (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    data JSONB NOT NULL,
    deleted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    purge_at TIMESTAMP WITH TIME ZONE DEFAULT (CURRENT_TIMESTAMP + INTERVAL '90 days')
);

-- 2. ARCHIVED DATA (Long-term historical storage)
CREATE TABLE IF NOT EXISTS recovery.archive (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL,
    table_name TEXT NOT NULL,
    data JSONB NOT NULL,
    reason TEXT DEFAULT 'manual_archive',
    archived_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indices for fast lookup
CREATE INDEX idx_recovery_delete_user ON recovery.delete(user_id);
CREATE INDEX idx_recovery_archive_user ON recovery.archive(user_id);
CREATE INDEX idx_recovery_purge_timer ON recovery.delete(purge_at);

-- ==========================================================
-- Functions for Recovery & Data Lifecycle
-- ==========================================================

-------------- 1. The Auto-Delete Trigger --------------
CREATE OR REPLACE FUNCTION recovery.trg_smart_delete_handler()
RETURNS TRIGGER AS $$
DECLARE
    is_archiving TEXT;
BEGIN
    -- Check if the 'archiving' flag is set in the current session
    SHOW session.is_archiving INTO is_archiving;
    
    -- If we are archiving, do NOT insert into recovery.delete
    IF is_archiving = 'true' THEN
        RETURN OLD;
    END IF;

    -- Otherwise, proceed with moving data to the 90-day recovery vault
    INSERT INTO recovery.delete (user_id, table_name, data)
    VALUES (
        COALESCE(OLD.user_id, OLD.id), 
        TG_TABLE_NAME, 
        to_jsonb(OLD)
    );
    RETURN OLD;
EXCEPTION WHEN OTHERS THEN
    -- Fallback if the session variable isn't initialized
    INSERT INTO recovery.delete (user_id, table_name, data)
    VALUES (COALESCE(OLD.user_id, OLD.id), TG_TABLE_NAME, to_jsonb(OLD));
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;


-------------- 2. Manual Archive Function --------------
CREATE OR REPLACE FUNCTION recovery.move_to_archive(
    p_table_name TEXT,
    p_row_id UUID,
    p_user_id UUID
) RETURNS VOID AS $$
DECLARE
    row_data JSONB;
BEGIN
    -- 1. Enable archiving mode for this session
    SET LOCAL session.is_archiving = 'true';

    -- 2. Capture the data
    EXECUTE format('SELECT to_jsonb(t) FROM %I t WHERE id = %L', p_table_name, p_row_id) 
    INTO row_data;

    -- 3. Insert into long-term archive
    INSERT INTO recovery.archive (user_id, table_name, data, reason)
    VALUES (p_user_id, p_table_name, row_data, 'manual_archive');

    -- 4. Delete from live table (Trigger will see the flag and skip recovery.delete)
    EXECUTE format('DELETE FROM %I WHERE id = %L', p_table_name, p_row_id);

    -- 5. Reset flag (Optional, as LOCAL resets at end of transaction)
    SET LOCAL session.is_archiving = 'false';
END;
$$ LANGUAGE plpgsql;


-------------- 3. The Universal Restore Function --------------
CREATE OR REPLACE FUNCTION recovery.restore(
    p_recovery_type TEXT,
    p_record_id UUID
) RETURNS VOID AS $$
DECLARE
    v_table_name TEXT;
    v_data JSONB;
BEGIN
    IF p_recovery_type = 'archive' THEN
        SELECT table_name, data INTO v_table_name, v_data 
        FROM recovery.archive WHERE id = p_record_id;
    ELSIF p_recovery_type = 'delete' THEN
        SELECT table_name, data INTO v_table_name, v_data 
        FROM recovery.delete WHERE id = p_record_id;
    ELSE
        RAISE EXCEPTION 'Invalid recovery type. Use archive or delete.';
    END IF;

    IF v_data IS NULL THEN
        RAISE EXCEPTION 'Record not found in recovery schema.';
    END IF;
    EXECUTE format(
        'INSERT INTO %I SELECT * FROM jsonb_populate_record(NULL::%I, %L)', 
        v_table_name, v_table_name, v_data
    );
    IF p_recovery_type = 'archive' THEN
        DELETE FROM recovery.archive WHERE id = p_record_id;
    ELSE
        DELETE FROM recovery.delete WHERE id = p_record_id;
    END IF;
END;
$$ LANGUAGE plpgsql;


-------------- 4. The Bulk Restore Function --------------
CREATE OR REPLACE FUNCTION recovery.bulk_restore(
    p_restore_type TEXT,
    p_user_id UUID
) RETURNS TABLE (table_name TEXT, restored_count INTEGER) AS $$
DECLARE
    v_record RECORD;
    v_count INTEGER := 0;
BEGIN
    IF p_restore_type = 'delete' THEN
        -- 1. Restore from the 90-day Delete Vault first
        FOR v_record IN 
            SELECT id, table_name FROM recovery.delete WHERE user_id = p_user_id
        LOOP
            PERFORM recovery.restore_from_recovery('delete', v_record.id);
            v_count := v_count + 1;
        END LOOP;
    ELSIF p_recovery_type = 'archive' THEN
        -- 2. Restore from the Long-term Archive
        FOR v_record IN 
            SELECT id, table_name FROM recovery.archive WHERE user_id = p_user_id
        LOOP
            PERFORM recovery.restore_from_recovery('archive', v_record.id);
            v_count := v_count + 1;
        END LOOP;
    ELSE
        RAISE EXCEPTION 'Invalid restore type. Use archive or delete.';
    END IF;

    RETURN QUERY SELECT 'Total Records Restored'::TEXT, v_count;
END;
$$ LANGUAGE plpgsql;


-------------- 5. Permanently Delete (The Purge) --------------
CREATE OR REPLACE FUNCTION recovery.purge_expired_deletes()
RETURNS TABLE (purged_count INTEGER) AS $$
DECLARE
    deleted_rows INTEGER;
BEGIN
    DELETE FROM recovery.delete
    WHERE purge_at < CURRENT_TIMESTAMP;
    
    GET DIAGNOSTICS deleted_rows = ROW_COUNT;
    RETURN QUERY SELECT deleted_rows;
END;
$$ LANGUAGE plpgsql;



-- /////////////////////////////////////////////////////////////
-- Applyed Schemas or Tables
-- /////////////////////////////////////////////////////////////

-- Apply to Public Core
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.avatars FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.date FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.geo_coordinates FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.maps FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.org_hierarchy FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.orgz FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.questionsets FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON public.social FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();


-- Apply to Auth Schema
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.credentials FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.identities FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.mfa FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.login_history FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.mobile_device_registrations FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.mobile_number_verifications FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_user_cleanup BEFORE DELETE ON auth.security_answers FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();

-- Apply to RBAC Schema
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON rbac.permissions FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON rbac.resources FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON rbac.roles FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON rbac.user_assignments FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();

-- Apply to FORMAT Schema
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.address FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.country FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.currency FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.date FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.number FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.time FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();
CREATE TRIGGER trg_pers_cleanup BEFORE DELETE ON format.timezone FOR EACH ROW EXECUTE FUNCTION recovery.trg_smart_delete_handler();

