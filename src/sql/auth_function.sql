
-- ///////////// MASTER FUNCTIONS /////////////
-- Master Function: Manage Identity (Insert/Update/Delete)
CREATE OR REPLACE FUNCTION auth.manage_identity(
    p_action VARCHAR,
    p_user_id UUID,
    p_identity_type VARCHAR,
    p_identifier CITEXT,
    p_provider VARCHAR DEFAULT 'local',
    p_provider_id TEXT DEFAULT NULL,
    p_is_verified BOOLEAN DEFAULT FALSE,
    p_is_primary BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
BEGIN
    IF p_action = 'insert' THEN
        INSERT INTO auth.identities (user_id, identity_type, identifier, provider, provider_id, is_verified, is_primary)
        VALUES (p_user_id, p_identity_type, p_identifier, p_provider, p_provider_id, p_is_verified, p_is_primary);
    ELSIF p_action = 'update' THEN
        UPDATE auth.identities
        SET is_verified = p_is_verified, is_primary = p_is_primary,
            provider_id = COALESCE(p_provider_id, provider_id),
            updated_at = CURRENT_TIMESTAMP
        WHERE user_id = p_user_id AND identity_type = p_identity_type AND identifier = p_identifier;
    ELSIF p_action = 'delete' THEN
        DELETE FROM auth.identities
        WHERE user_id = p_user_id AND identity_type = p_identity_type AND identifier = p_identifier;
    ELSE
        RAISE EXCEPTION 'Invalid action. Use insert, update, or delete.';
    END IF;
END;
$$ LANGUAGE plpgsql;