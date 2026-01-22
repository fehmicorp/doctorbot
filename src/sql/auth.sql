-- ==========================================================
-- FEHMI SINGLE SIGN ON (SSO) MASTER SCHEMA
-- Version: 2026.1.1 | Mode: Production
-- ==========================================================

-- 1. EXTENSIONS & SCHEMAS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION pg_cron;

-- CREATE SCHEMA IF NOT EXISTS auth;
-- CREATE SCHEMA IF NOT EXISTS profile;
-- CREATE SCHEMA IF NOT EXISTS format;
-- CREATE SCHEMA IF NOT EXISTS recovery;

-- ==========================================================
-- AUTHENTICATION TABLES
-- ==========================================================
CREATE SCHEMA IF NOT EXISTS auth;

-- IDENTITIES (Email, Phone, OAuth)
CREATE TABLE IF NOT EXISTS auth.identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    identity_type VARCHAR(10) CHECK (identity_type IN ('email', 'phone', 'username', 'oauth')),
    identifier CITEXT NOT NULL,
    provider VARCHAR(20) DEFAULT 'local',
    is_verified BOOLEAN DEFAULT FALSE,
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(identity_type, identifier, provider)
);

-- CORE AUTHENTICATION
CREATE TABLE IF NOT EXISTS auth.credentials (
    user_id UUID PRIMARY KEY REFERENCES public.user(id) ON DELETE CASCADE,
    password_hash TEXT NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_identities_lookup ON auth.identities (created_at) WHERE is_verified IS TRUE;
CREATE INDEX idx_identities_primary_verified ON auth.identities (identifier) WHERE is_verified IS TRUE AND is_primary IS TRUE AND provider = 'local';

-- SESSION MANAGEMENT (With Revocation)
CREATE TABLE IF NOT EXISTS auth.sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    refresh_token TEXT UNIQUE NOT NULL,
    user_agent TEXT,
    ip_address INET,
    is_revoked BOOLEAN DEFAULT FALSE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- MFA, SESSIONS, & LOGGING
CREATE TABLE IF NOT EXISTS auth.mfa (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    mfa_enabled BOOLEAN DEFAULT FALSE,
    mfa_type VARCHAR(20),
    secret TEXT NOT NULL,
    recovery_codes TEXT[],
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, mfa_type)
);

-- AUDIT & LOGGING
CREATE TABLE IF NOT EXISTS auth.login_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    login_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    logout_at TIMESTAMP WITH TIME ZONE,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN DEFAULT TRUE,
    failure_reason TEXT,
    metadata JSONB DEFAULT '{}'
);

CREATE INDEX idx_mfa_enabled on auth.mfa (mfa_type) WHERE mfa_enabled IS TRUE;
CREATE INDEX idx_login_history_user on auth.login_history (login_at) WHERE success IS TRUE;

-- MOBILE NUMBER VERIFICATIONS & SECURITY
CREATE TABLE IF NOT EXISTS auth.mobile_number_verifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    verification_code TEXT,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, verification_code)
);

-- MOBILE DEVICE REGISTRATIONS
CREATE TABLE auth.mobile_device_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    device_token TEXT UNIQUE NOT NULL,
    device_type VARCHAR(20) CHECK (device_type IN ('ios', 'android')),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_location JSONB,
    last_used_at TIMESTAMP WITH TIME ZONE,
    UNIQUE(user_id, device_type, device_token)
);

-- SECURITY QUESTIONS & ANSWERS

CREATE TABLE auth.security_questions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES public.user(id) ON DELETE CASCADE,
    question_ids UUID[] NOT NULL, 
    answer_hashes TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_user_security_profile UNIQUE(user_id)
);
CREATE INDEX idx_security_questions_user ON auth.security_questions(user_id);

-- ==========================================================
-- FINAL AUTH LIFECYCLE & HOUSEKEEPING (2026.01)
-- ==========================================================

CREATE OR REPLACE FUNCTION auth.f_set_security_answers(
    p_user_id UUID,
    p_question_ids UUID[],
    p_plain_answers TEXT[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_hashed_answers TEXT[] := '{}';
    v_ans TEXT;
BEGIN
    -- Ensure array lengths match
    IF array_length(p_question_ids, 1) != array_length(p_plain_answers, 1) THEN
        RAISE EXCEPTION 'Mismatch: Question IDs and Answers must have the same count.';
    END IF;

    -- Encrypt each answer using pgcrypto
    FOREACH v_ans IN ARRAY p_plain_answers LOOP
        v_hashed_answers := array_append(v_hashed_answers, crypt(v_ans, gen_salt('bf', 8)));
    END LOOP;

    -- Upsert into the renamed table
    INSERT INTO auth.security_answers (user_id, question_ids, answer_hashes)
    VALUES (p_user_id, p_question_ids, v_hashed_answers)
    ON CONFLICT (user_id) DO UPDATE SET 
        question_ids = EXCLUDED.question_ids,
        answer_hashes = EXCLUDED.answer_hashes,
        updated_at = CURRENT_TIMESTAMP;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION auth.f_get_user_questions(p_user_id UUID)
RETURNS TABLE (q_id UUID, q_text TEXT) AS $$
BEGIN
    RETURN QUERY
    WITH user_ids AS (
        SELECT unnest(question_ids) as id, generate_subscripts(question_ids, 1) as ord
        FROM auth.security_answers WHERE user_id = p_user_id
    )
    SELECT ui.id, qs.questions_sets[1] -- Extracts the first question from the set
    FROM user_ids ui
    JOIN public.questionsets qs ON qs.id = ui.id
    ORDER BY ui.ord;
END;
$$ LANGUAGE plpgsql STABLE;


CREATE OR REPLACE FUNCTION auth.f_verify_security_answers(
    p_user_id UUID,
    p_input_answers TEXT[]
) RETURNS BOOLEAN AS $$
DECLARE
    v_hashes TEXT[];
    v_correct BOOLEAN := TRUE;
BEGIN
    SELECT answer_hashes INTO v_hashes FROM auth.security_answers WHERE user_id = p_user_id;

    IF v_hashes IS NULL OR array_length(v_hashes, 1) != array_length(p_input_answers, 1) THEN
        RETURN FALSE;
    END IF;

    FOR i IN 1 .. array_length(v_hashes, 1) LOOP
        -- Compare input against stored hash
        IF v_hashes[i] != crypt(p_input_answers[i], v_hashes[i]) THEN
            v_correct := FALSE;
            EXIT; -- Fail fast
        END IF;
    END LOOP;

    RETURN v_correct;
END;
$$ LANGUAGE plpgsql STABLE;


-- 1. USER LOGIN (Internal Helper)
CREATE OR REPLACE FUNCTION auth.user_login(
    p_user_id UUID,
    p_refresh_token TEXT,
    p_expires_at TIMESTAMP WITH TIME ZONE,
    p_ip INET,
    p_user_agent TEXT,
    p_metadata JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    v_session_id UUID;
    v_audit_meta JSONB;
BEGIN
    -- Create the Session
    INSERT INTO auth.sessions (user_id, refresh_token, ip_address, user_agent, expires_at)
    VALUES (p_user_id, p_refresh_token, p_ip, p_user_agent, p_expires_at)
    RETURNING id INTO v_session_id;

    -- Merge session_id into metadata for better tracking in history
    v_audit_meta := p_metadata || jsonb_build_object('session_id', v_session_id);

    -- Audit the Login
    INSERT INTO auth.login_history (user_id, ip_address, user_agent, metadata)
    VALUES (p_user_id, p_ip, p_user_agent, v_audit_meta);

    -- Update user activity
    UPDATE public.user SET last_login_at = now() WHERE id = p_user_id;

    RETURN v_session_id;
END;
$$ LANGUAGE plpgsql;

-- 2. UNIFIED SIGN-IN (Entry Point)
CREATE OR REPLACE FUNCTION auth.f_signin(
    p_identifier TEXT,
    p_password   TEXT DEFAULT NULL,
    p_provider   TEXT DEFAULT 'local', 
    p_metadata   JSONB DEFAULT '{}'
) 
RETURNS TABLE (
    success BOOLEAN, 
    message TEXT, 
    user_id UUID, 
    access_level SMALLINT, 
    session_id UUID
) AS $$
DECLARE
    v_user_id UUID; 
    v_pass_hash TEXT; 
    v_is_verified BOOLEAN;
    v_session_id UUID; 
    v_access_level SMALLINT;
    -- Safe casting with COALESCE to prevent null errors on INET
    v_ip INET := COALESCE((p_metadata->>'ip'), '0.0.0.0')::INET;
    v_ua TEXT := p_metadata->>'useragent';
    v_refresh_tok TEXT := encode(gen_random_bytes(32), 'hex');
BEGIN
    -- 1. Identify the user
    SELECT i.user_id, i.is_verified INTO v_user_id, v_is_verified
    FROM auth.identities i 
    WHERE i.identifier = p_identifier::CITEXT 
      AND i.provider = p_provider;

    IF v_user_id IS NULL THEN
        INSERT INTO auth.login_history (user_id, success, failure_reason, ip_address, user_agent, metadata)
        VALUES (NULL, FALSE, 'User not found', v_ip, v_ua, p_metadata);
        
        RETURN QUERY SELECT FALSE, 'Authentication failed'::TEXT, NULL::UUID, 0::SMALLINT, NULL::UUID;
        RETURN;
    END IF;

    -- 2. Password verification for local provider
    IF p_provider = 'local' THEN
        SELECT password_hash INTO v_pass_hash FROM auth.credentials WHERE user_id = v_user_id;
        
        -- Use crypt() for secure comparison
        IF v_pass_hash IS NULL OR v_pass_hash != crypt(p_password, v_pass_hash) THEN
            INSERT INTO auth.login_history (user_id, success, failure_reason, ip_address, user_agent, metadata)
            VALUES (v_user_id, FALSE, 'Invalid credentials', v_ip, v_ua, p_metadata);
            
            RETURN QUERY SELECT FALSE, 'Authentication failed'::TEXT, v_user_id, 0::SMALLINT, NULL::UUID;
            RETURN;
        END IF;
    END IF;

    -- 3. Get RBAC Access Level
    SELECT COALESCE(MAX(perm.access_level), 0) INTO v_access_level
    FROM rbac.permissions perm 
    JOIN rbac.user_assignments ua ON perm.role_id = ua.role_id
    WHERE ua.user_id = v_user_id;

    -- 4. Create Session (Calling the renamed f_session_create function)
    v_session_id := auth.f_session_create(
        v_user_id, 
        v_refresh_tok, 
        (now() + INTERVAL '7 days'), 
        v_ip, 
        v_ua, 
        p_metadata
    );

    -- 5. Return success
    RETURN QUERY SELECT TRUE, 'Access granted'::TEXT, v_user_id, v_access_level, v_session_id;
END;
$$ LANGUAGE plpgsql;

-- 3. TOKEN REFRESH (Cycle)
CREATE OR REPLACE FUNCTION auth.refresh_session(
    p_old_refresh_token TEXT,
    p_metadata JSONB DEFAULT '{}'
) RETURNS TABLE (success BOOLEAN, message TEXT, user_id UUID, new_refresh_token TEXT, expires_at TIMESTAMP WITH TIME ZONE) AS $$
DECLARE
    v_user_id UUID; v_session_id UUID; v_new_token TEXT := encode(gen_random_bytes(32), 'hex');
    v_new_expiry TIMESTAMP WITH TIME ZONE := (now() + INTERVAL '7 days');
    v_ip INET := (p_metadata->>'ip')::INET; v_ua TEXT := p_metadata->>'useragent';
BEGIN
    SELECT id, user_id INTO v_session_id, v_user_id FROM auth.sessions
    WHERE refresh_token = p_old_refresh_token AND is_revoked = FALSE AND expires_at > now();

    IF v_session_id IS NULL THEN
        RETURN QUERY SELECT FALSE, 'Invalid token'::TEXT, NULL::UUID, NULL::TEXT, NULL::TIMESTAMP WITH TIME ZONE;
        RETURN;
    END IF;

    UPDATE auth.sessions SET is_revoked = TRUE, updated_at = now() WHERE id = v_session_id;
    
    PERFORM auth.user_login(v_user_id, v_new_token, v_new_expiry, v_ip, v_ua, p_metadata || '{"reason": "rotation"}');

    RETURN QUERY SELECT TRUE, 'Rotated'::TEXT, v_user_id, v_new_token, v_new_expiry;
END;
$$ LANGUAGE plpgsql;

-- 4. LOGOUT (Exit)
CREATE OR REPLACE FUNCTION auth.user_logout(
    p_session_id UUID,
    p_user_id UUID
) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE auth.sessions SET is_revoked = TRUE, updated_at = now() 
    WHERE id = p_session_id AND user_id = p_user_id;

    UPDATE auth.login_history SET logout_at = now() 
    WHERE user_id = p_user_id AND (metadata->>'session_id')::UUID = p_session_id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;

-- HOUSEKEEPING: Purge sessions older than 1 day that are already revoked or expired.
CREATE OR REPLACE FUNCTION auth.purge_stale_sessions() 
RETURNS VOID AS $$
BEGIN
    -- Only delete if they are TRULY stale to keep the table size under control.
    -- Because of your "trg_smart_delete_handler", these will be moved to recovery.delete
    -- so you still have a 90-day window to see them in the vault if needed.
    DELETE FROM auth.sessions 
    WHERE is_revoked = TRUE 
       OR expires_at < (now() - INTERVAL '1 day');
END;
$$ LANGUAGE plpgsql;

-- To schedule in PostgreSQL (if pg_cron is enabled):
SELECT cron.schedule('0 0,6,12,18 * * *', 'SELECT auth.purge_stale_sessions();');


-- ==========================================================
-- RBAC: MULTI-ORG & SSO COMPATIBLE (2026.1.1)
-- ==========================================================
CREATE SCHEMA IF NOT EXISTS rbac;
CREATE SCHEMA IF NOT EXISTS test; -- Sandbox schema for Test permissions

-- 1. RESOURCES
CREATE TABLE IF NOT EXISTS rbac.resources (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug CITEXT UNIQUE NOT NULL, -- e.g., 'profile.personal'
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. ROLES (Organization Scoped)
CREATE TABLE IF NOT EXISTS rbac.roles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    orgz_id UUID REFERENCES public.org_hierarchy(id) ON DELETE CASCADE,
    slug CITEXT NOT NULL, 
    name TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(orgz_id, slug)
);

-- 3. PERMISSION MATRIX (Numeric Levels 0-9)
CREATE TABLE IF NOT EXISTS rbac.permissions (
    role_id UUID REFERENCES rbac.roles(id) ON DELETE CASCADE,
    resource_id UUID REFERENCES rbac.resources(id) ON DELETE CASCADE,
    access_level SMALLINT CHECK (access_level BETWEEN 0 AND 9) DEFAULT 0,
    PRIMARY KEY (role_id, resource_id)
);

-- 4. USER ASSIGNMENTS
CREATE TABLE IF NOT EXISTS rbac.user_assignments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.user(id) ON DELETE CASCADE,
    orgz_id UUID REFERENCES public.orgz(id) ON DELETE CASCADE,
    role_id UUID REFERENCES rbac.roles(id) ON DELETE CASCADE,
    assigned_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, orgz_id, role_id)
);

-- Permission Name	    ID
-- Disabled             0
-- Restricted Read	    1
-- Full Read	        2
-- Test	rwx             3
-- Create	            4
-- Create/Write	        5
-- Create/Edit/Write    6
-- Test	rwxcd           7
-- Delete	            8
-- Full Control	        9

