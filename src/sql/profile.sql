-- ///////////// PROFILE SCHEMA SETUP /////////////
CREATE SCHEMA IF NOT EXISTS profile;

-- 1. USER PROFILE ANCHOR
-- Acts as the central link between Auth and Profile data
CREATE TABLE IF NOT EXISTS profile.users (
    user_id UUID PRIMARY KEY REFERENCES public.credentials(user_id) ON DELETE CASCADE,
    email CITEXT UNIQUE, 
    phone CITEXT UNIQUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. AVATAR MANAGEMENT
-- Must be created before 'personal' so 'personal' can reference 'avatar_id'
CREATE TABLE IF NOT EXISTS profile.avatars (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES public.credentials(user_id) ON DELETE CASCADE,
    title TEXT DEFAULT 'untitled',
    is_primary BOOLEAN DEFAULT FALSE,
    uploaded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 3. DETAILED PERSONAL INFORMATION
CREATE TABLE IF NOT EXISTS profile.personal(
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES profile.users(user_id) ON DELETE CASCADE,
    full_name VARCHAR(100),
    avatar_id UUID REFERENCES profile.avatars(id) ON DELETE SET NULL,
    name_json JSONB, -- Stores { "first": "", "last": "" }
    gender VARCHAR(1) CHECK (gender IN ('M', 'F', 'O')),
    date_of_birth DATE,
    anniversary DATE,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ///////////// AVATAR LOGIC FUNCTION /////////////

CREATE OR REPLACE FUNCTION profile.manage_avatar(
    p_action VARCHAR, -- 'insert', 'delete', 'set_primary'
    p_user_id UUID,
    p_title TEXT DEFAULT 'untitled',
    p_avatar_id UUID DEFAULT NULL,
    p_is_primary BOOLEAN DEFAULT FALSE
)
RETURNS VOID AS $$
BEGIN
    -- ACTION: INSERT
    IF p_action = 'insert' THEN
        -- If this new one is primary, demote others first
        IF p_is_primary THEN
            UPDATE profile.avatars SET is_primary = FALSE WHERE user_id = p_user_id;
        END IF;

        INSERT INTO profile.avatars (user_id, is_primary, title) 
        VALUES (p_user_id, p_is_primary, p_title)
        RETURNING id INTO p_avatar_id;

        -- If it was primary, update the personal profile link
        IF p_is_primary THEN
            UPDATE profile.personal SET avatar_id = p_avatar_id WHERE user_id = p_user_id;
        END IF;

    -- ACTION: DELETE
    ELSIF p_action = 'delete' THEN
        -- If we are deleting the current primary, clear the profile link first
        UPDATE profile.personal SET avatar_id = NULL 
        WHERE user_id = p_user_id AND avatar_id = p_avatar_id;
        
        DELETE FROM profile.avatars WHERE id = p_avatar_id AND user_id = p_user_id;

    -- ACTION: SET PRIMARY (Update)
    ELSIF p_action = 'set_primary' THEN
        UPDATE profile.avatars SET is_primary = FALSE WHERE user_id = p_user_id;
        UPDATE profile.avatars SET is_primary = TRUE WHERE id = p_avatar_id AND user_id = p_user_id;
        UPDATE profile.personal SET avatar_id = p_avatar_id WHERE user_id = p_user_id;
    END IF;
END;
$$ LANGUAGE plpgsql;