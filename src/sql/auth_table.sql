CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE SCHEMA IF NOT EXISTS auth;

-- 1. CORE AUTHENTICATION (Anchor Table)
CREATE TABLE IF NOT EXISTS auth.credentials (
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    password_hash TEXT DEFAULT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. IDENTITIES (Linked to Credentials)
CREATE TABLE IF NOT EXISTS auth.identities (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    identity_type VARCHAR(10) CHECK (identity_type IN ("email", "phone", "username", "oauth")),
    identifier CITEXT NOT NULL,
    provider VARCHAR(20) DEFAULT "local",
    provider_id TEXT,
    is_verified BOOLEAN DEFAULT FALSE,
    is_primary BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(identity_type, identifier, provider)
);

-- 3. MFA, SESSIONS, & LOGGING
CREATE TABLE IF NOT EXISTS auth.mfa (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    mfa_enabled BOOLEAN DEFAULT FALSE,
    mfa_type VARCHAR(20) CHECK (mfa_type IN ("totp", "sms", "email")),
    secret TEXT NOT NULL,
    recovery_codes TEXT[],
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 4. SESSION MANAGEMENT (With Revocation)
CREATE TABLE IF NOT EXISTS auth.sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    refresh_token TEXT UNIQUE NOT NULL,
    user_agent TEXT,
    ip_address INET,
    is_revoked BOOLEAN DEFAULT FALSE,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 5. AUDIT & LOGGING
CREATE TABLE IF NOT EXISTS auth.login_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    login_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    logout_at TIMESTAMP WITH TIME ZONE,
    ip_address INET,
    user_agent TEXT,
    success BOOLEAN DEFAULT TRUE,
    failure_reason TEXT,
    metadata JSONB DEFAULT "{}"
);

-- 6. MOBILE NUMBER VERIFICATIONS & SECURITY
CREATE TABLE IF NOT EXISTS auth.mobile_number_verifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    verification_code TEXT,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 7. MOBILE DEVICE REGISTRATIONS
CREATE TABLE auth.mobile_device_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    device_token TEXT UNIQUE NOT NULL,
    device_type VARCHAR(20) CHECK (device_type IN ("ios", "android")),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_location JSONB,
    last_used_at TIMESTAMP WITH TIME ZONE
);

-- 8. SECURITY QUESTIONS
CREATE TABLE IF NOT EXISTS auth.security_questions (
    user_id UUID PRIMARY KEY REFERENCES profile.users(user_id) ON DELETE CASCADE,
    question TEXT[] NOT NULL,
    answer_hash TEXT[] NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
