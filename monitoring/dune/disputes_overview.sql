-- =============================================================================
-- ILRM Protocol - Disputes Overview Dashboard
-- =============================================================================
-- Platform: Dune Analytics
-- Network: Optimism (change to your deployed network)
-- Update: Replace 0x... with your deployed ILRM contract address
-- =============================================================================

-- Total Disputes Initiated
SELECT
    COUNT(*) as total_disputes,
    COUNT(CASE WHEN block_time >= NOW() - INTERVAL '24' HOUR THEN 1 END) as last_24h,
    COUNT(CASE WHEN block_time >= NOW() - INTERVAL '7' DAY THEN 1 END) as last_7d,
    COUNT(CASE WHEN block_time >= NOW() - INTERVAL '30' DAY THEN 1 END) as last_30d
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Replace with ILRM address
AND topic0 = 0x... -- DisputeInitiated event signature

-- Daily Dispute Trends
SELECT
    DATE_TRUNC('day', block_time) as date,
    COUNT(*) as disputes_initiated
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Replace with ILRM address
AND topic0 = 0x... -- DisputeInitiated event signature
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Dispute Resolution Breakdown
SELECT
    CASE
        WHEN topic0 = 0x... THEN 'Accepted Proposal'
        WHEN topic0 = 0x... THEN 'Timeout with Burn'
        WHEN topic0 = 0x... THEN 'Default License'
        ELSE 'Other'
    END as outcome,
    COUNT(*) as count
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Replace with ILRM address
AND topic0 IN (
    0x..., -- DisputeResolved (AcceptedProposal)
    0x..., -- DisputeResolved (TimeoutWithBurn)
    0x...  -- DefaultLicenseApplied
)
AND block_time >= NOW() - INTERVAL '30' DAY
GROUP BY 1

-- Average Dispute Duration (in hours)
WITH dispute_lifecycle AS (
    SELECT
        CAST(topic1 AS UINT256) as dispute_id,
        MIN(CASE WHEN topic0 = 0x... THEN block_time END) as initiated_at,
        MIN(CASE WHEN topic0 = 0x... THEN block_time END) as resolved_at
    FROM optimism.logs
    WHERE contract_address = 0x0000000000000000000000000000000000000000
    AND topic0 IN (0x..., 0x...) -- DisputeInitiated, DisputeResolved
    GROUP BY 1
)
SELECT
    AVG(DATE_DIFF('hour', initiated_at, resolved_at)) as avg_hours_to_resolve,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY DATE_DIFF('hour', initiated_at, resolved_at)) as median_hours
FROM dispute_lifecycle
WHERE resolved_at IS NOT NULL
AND initiated_at >= NOW() - INTERVAL '30' DAY
