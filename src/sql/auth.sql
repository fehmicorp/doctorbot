-- 1. SETUP EXTENSIONS & SCHEMA
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";

CREATE SCHEMA IF NOT EXISTS auth;

-- 2. CORE AUTHENTICATION
CREATE TABLE IF NOT EXISTS auth.credentials (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username CITEXT UNIQUE REFERENCES auth.identities(id) ON DELETE CASCADE,
    password_hash TEXT DEFAULT NULL,
    status_code SMALLINT DEFAULT 1,
    last_login_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. IDENTITIES (Email, Phone, OAuth)
CREATE TABLE IF NOT EXISTS auth.identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    identity_type VARCHAR(10) CHECK (identity_type IN ("email", "phone", "username", "oauth")),
    identifier CITEXT NOT NULL,
    provider VARCHAR(20) DEFAULT "local",
    provider_id TEXT,
    is_verified BOOLEAN DEFAULT FALSE,
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(identity_type, identifier, provider)
);

-- 4. MFA SETTINGS
CREATE TABLE IF NOT EXISTS auth.mfa (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    mfa_enabled BOOLEAN DEFAULT FALSE,
    mfa_type VARCHAR(20) CHECK (mfa_type IN ("totp", "sms", "email")),
    secret TEXT NOT NULL,
    recovery_codes TEXT[],
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. SESSION MANAGEMENT (With Revocation)
CREATE TABLE IF NOT EXISTS auth.sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    refresh_token TEXT UNIQUE NOT NULL,
    user_agent TEXT,
    ip_address INET,
    is_revoked BOOLEAN DEFAULT FALSE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 6. AUDIT & LOGGING
CREATE TABLE IF NOT EXISTS auth.login_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    login_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    logout_at TIMESTAMP WITH TIME ZONE,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN DEFAULT TRUE,
    failure_reason TEXT,
    metadata JSONB DEFAULT "{}"
);

-- 7. PASSWORD RESETS
CREATE TABLE auth.password_resets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    reset_token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    used BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 8. EMAIL VERIFICATIONS
CREATE TABLE auth.email_verifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    verification_token TEXT UNIQUE NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 9. Mobile Device Registrations
CREATE TABLE auth.mobile_device_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    device_token TEXT UNIQUE NOT NULL,
    device_type VARCHAR(20) CHECK (device_type IN ("ios", "android")),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_used_at TIMESTAMP WITH TIME ZONE
);

-- 10. Mobile Number Verifications
CREATE TABLE auth.mobile_number_verifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    verification_code TEXT NOT NULL,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 11. SECURITY QUESTIONS
CREATE TABLE auth.security_questions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES auth.credentials(user_id) ON DELETE CASCADE,
    question TEXT[] NOT NULL,
    answer_hash TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id)
);
-- ///////////// FUNCTIONS & TRIGGERS /////////////
-- Function to upsert multiple security questions at once
CREATE OR REPLACE FUNCTION auth.upsert_security_questions(
    p_user_id UUID,
    p_questions TEXT[],
    p_answers_hash TEXT[]
) RETURNS VOID AS $$
BEGIN
    -- Check if array lengths match to prevent data misalignment
    IF array_length(p_questions, 1) != array_length(p_answers_hash, 1) THEN
        RAISE EXCEPTION "Question and Answer array lengths must match.";
    END IF;

    INSERT INTO auth.security_questions (
        user_id, 
        question, 
        answer_hash, 
        updated_at
    )
    VALUES (
        p_user_id, 
        p_questions, 
        p_answers_hash, 
        now()
    )
    ON CONFLICT (user_id) 
    DO UPDATE SET 
        question = EXCLUDED.question,
        answer_hash = EXCLUDED.answer_hash,
        updated_at = now();
END;
$$ LANGUAGE plpgsql;

-- Function to generate a random 6-digit code
CREATE OR REPLACE FUNCTION auth.generate_6_digit_otp()
RETURNS TRIGGER AS $$
BEGIN
    -- Generates a number between 100000 and 999999 and converts to text
    NEW.verification_code := floor(random() * (999999 - 100000 + 1) + 100000)::text;
    
    -- Set default expiry to 5 minutes if not provided
    IF NEW.expires_at IS NULL THEN
        NEW.expires_at := now() + interval "5 minutes";
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- Auto-update "updated_at" timestamp
CREATE OR REPLACE FUNCTION auth.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply update triggers
CREATE TRIGGER tr_generate_otp BEFORE INSERT ON auth.mobile_number_verifications FOR EACH ROW EXECUTE FUNCTION auth.generate_6_digit_otp();
CREATE TRIGGER tr_credentials_updated BEFORE UPDATE ON auth.credentials FOR EACH ROW EXECUTE FUNCTION auth.set_updated_at();
CREATE TRIGGER tr_mfa_updated BEFORE UPDATE ON auth.mfa FOR EACH ROW EXECUTE FUNCTION auth.set_updated_at();
CREATE TRIGGER tr_sessions_updated BEFORE UPDATE ON auth.sessions FOR EACH ROW EXECUTE FUNCTION auth.set_updated_at();

-- ///////////// HIGH-PERFORMANCE INDEXES /////////////

-- Quick lookup for identities
CREATE INDEX idx_identities_lookup ON auth.identities (identifier, identity_type, provider);

-- Fast session verification (only index non-expired, non-revoked tokens)
CREATE INDEX idx_active_sessions_manual 
ON auth.sessions (refresh_token) 
WHERE (is_revoked IS FALSE);

-- History tracking for a specific user
CREATE INDEX idx_login_history_user ON auth.login_history (user_id, login_at DESC);