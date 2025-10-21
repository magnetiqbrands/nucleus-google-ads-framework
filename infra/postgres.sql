-- PostgreSQL schema for Google Ads Automation API
-- Tables: clients, api_logs, audit

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Clients table
CREATE TABLE IF NOT EXISTS clients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    customer_id VARCHAR(20) UNIQUE NOT NULL,
    name VARCHAR(255) NOT NULL,
    tier VARCHAR(20) NOT NULL DEFAULT 'bronze',
    quota_daily INTEGER NOT NULL DEFAULT 10000,
    status VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    metadata JSONB DEFAULT '{}'::jsonb
);

CREATE INDEX idx_clients_customer_id ON clients(customer_id);
CREATE INDEX idx_clients_tier ON clients(tier);
CREATE INDEX idx_clients_status ON clients(status);

-- API logs table (for request/response tracking)
CREATE TABLE IF NOT EXISTS api_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    client_id VARCHAR(20) NOT NULL,
    operation_type VARCHAR(50) NOT NULL,
    endpoint VARCHAR(255) NOT NULL,
    request_data JSONB,
    response_status INTEGER,
    response_time_ms INTEGER,
    quota_charged INTEGER DEFAULT 0,
    error_code VARCHAR(50),
    error_message TEXT,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    user_id VARCHAR(255),
    tier VARCHAR(20)
);

-- Partitioning by month for better performance
CREATE INDEX idx_api_logs_timestamp ON api_logs(timestamp DESC);
CREATE INDEX idx_api_logs_client_id ON api_logs(client_id, timestamp DESC);
CREATE INDEX idx_api_logs_operation_type ON api_logs(operation_type);
CREATE INDEX idx_api_logs_error_code ON api_logs(error_code) WHERE error_code IS NOT NULL;

-- Audit trail table (append-only for admin actions)
CREATE TABLE IF NOT EXISTS audit (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    event_type VARCHAR(50) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    actor_role VARCHAR(50) NOT NULL,
    resource_type VARCHAR(50),
    resource_id VARCHAR(255),
    action VARCHAR(100) NOT NULL,
    changes JSONB,
    ip_address INET,
    user_agent TEXT,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    hash_prev VARCHAR(64),  -- For tamper-evident chain
    hash_current VARCHAR(64)  -- SHA-256 of this record + prev hash
);

CREATE INDEX idx_audit_timestamp ON audit(timestamp DESC);
CREATE INDEX idx_audit_actor ON audit(actor_id, timestamp DESC);
CREATE INDEX idx_audit_resource ON audit(resource_type, resource_id);
CREATE INDEX idx_audit_event_type ON audit(event_type);

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_clients_updated_at
    BEFORE UPDATE ON clients
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Function to compute audit hash (tamper-evident chain)
CREATE OR REPLACE FUNCTION compute_audit_hash()
RETURNS TRIGGER AS $$
DECLARE
    record_data TEXT;
    prev_hash TEXT;
BEGIN
    -- Get previous hash
    SELECT hash_current INTO prev_hash
    FROM audit
    ORDER BY timestamp DESC
    LIMIT 1;

    -- Compute hash of current record + previous hash
    record_data := COALESCE(prev_hash, '') ||
                   NEW.id::text ||
                   NEW.event_type ||
                   NEW.actor_id ||
                   COALESCE(NEW.action, '') ||
                   NEW.timestamp::text;

    NEW.hash_prev = prev_hash;
    NEW.hash_current = encode(digest(record_data, 'sha256'), 'hex');

    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER audit_hash_trigger
    BEFORE INSERT ON audit
    FOR EACH ROW
    EXECUTE FUNCTION compute_audit_hash();

-- Sample data for development
INSERT INTO clients (customer_id, name, tier, quota_daily, status)
VALUES
    ('1234567890', 'Demo Client Gold', 'gold', 100000, 'active'),
    ('0987654321', 'Demo Client Silver', 'silver', 50000, 'active'),
    ('1122334455', 'Demo Client Bronze', 'bronze', 10000, 'active')
ON CONFLICT (customer_id) DO NOTHING;

-- Views for monitoring

-- Quota usage by client (last 24h)
CREATE OR REPLACE VIEW quota_usage_24h AS
SELECT
    client_id,
    tier,
    COUNT(*) as request_count,
    SUM(quota_charged) as total_quota_used,
    AVG(response_time_ms) as avg_response_time_ms,
    COUNT(*) FILTER (WHERE error_code IS NOT NULL) as error_count,
    MAX(timestamp) as last_request_at
FROM api_logs
WHERE timestamp > NOW() - INTERVAL '24 hours'
GROUP BY client_id, tier;

-- Error summary (last hour)
CREATE OR REPLACE VIEW error_summary_1h AS
SELECT
    error_code,
    COUNT(*) as occurrences,
    array_agg(DISTINCT client_id) as affected_clients,
    MIN(timestamp) as first_seen,
    MAX(timestamp) as last_seen
FROM api_logs
WHERE error_code IS NOT NULL
  AND timestamp > NOW() - INTERVAL '1 hour'
GROUP BY error_code
ORDER BY occurrences DESC;

-- Audit trail summary
CREATE OR REPLACE VIEW audit_summary AS
SELECT
    DATE(timestamp) as date,
    event_type,
    COUNT(*) as event_count,
    COUNT(DISTINCT actor_id) as unique_actors
FROM audit
WHERE timestamp > NOW() - INTERVAL '7 days'
GROUP BY DATE(timestamp), event_type
ORDER BY date DESC, event_count DESC;

-- Grant permissions (adjust user as needed)
-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ads_api_user;
-- GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ads_api_user;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO ads_api_user;
