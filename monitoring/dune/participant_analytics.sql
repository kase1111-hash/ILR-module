-- =============================================================================
-- ILRM Protocol - Participant Analytics Dashboard
-- =============================================================================
-- Platform: Dune Analytics
-- Network: Optimism (change to your deployed network)
-- =============================================================================

-- Unique Participants Over Time
SELECT
    DATE_TRUNC('day', block_time) as date,
    COUNT(DISTINCT topic1) as unique_initiators,
    COUNT(DISTINCT topic2) as unique_counterparties
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- ILRM address
AND topic0 = 0x... -- DisputeInitiated
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Top Participants by Dispute Count
SELECT
    address,
    total_disputes,
    as_initiator,
    as_counterparty,
    total_staked_eth
FROM (
    SELECT
        topic1 as address,
        COUNT(*) as total_disputes,
        COUNT(*) as as_initiator,
        0 as as_counterparty,
        SUM(CAST(data AS UINT256)) / 1e18 as total_staked_eth
    FROM optimism.logs
    WHERE contract_address = 0x0000000000000000000000000000000000000000
    AND topic0 = 0x... -- DisputeInitiated
    GROUP BY 1

    UNION ALL

    SELECT
        topic2 as address,
        COUNT(*) as total_disputes,
        0 as as_initiator,
        COUNT(*) as as_counterparty,
        SUM(CAST(data AS UINT256)) / 1e18 as total_staked_eth
    FROM optimism.logs
    WHERE contract_address = 0x0000000000000000000000000000000000000000
    AND topic0 = 0x... -- StakeDeposited (counterparty)
    GROUP BY 1
) combined
ORDER BY total_disputes DESC
LIMIT 100

-- Harassment Score Distribution
SELECT
    CASE
        WHEN CAST(data AS UINT256) = 0 THEN '0 (Clean)'
        WHEN CAST(data AS UINT256) BETWEEN 1 AND 10 THEN '1-10 (Low)'
        WHEN CAST(data AS UINT256) BETWEEN 11 AND 30 THEN '11-30 (Medium)'
        WHEN CAST(data AS UINT256) BETWEEN 31 AND 50 THEN '31-50 (High)'
        ELSE '50+ (Blocked)'
    END as score_bucket,
    COUNT(DISTINCT topic1) as participant_count
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- HarassmentScoreUpdated
GROUP BY 1
ORDER BY 1

-- Repeat Dispute Pairs (Potential Harassment)
SELECT
    CONCAT(LEAST(topic1, topic2), '-', GREATEST(topic1, topic2)) as pair,
    topic1 as initiator,
    topic2 as counterparty,
    COUNT(*) as dispute_count,
    MIN(block_time) as first_dispute,
    MAX(block_time) as last_dispute
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- DisputeInitiated
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1, 2, 3
HAVING COUNT(*) > 1
ORDER BY dispute_count DESC
LIMIT 50

-- New vs Returning Participants
WITH first_appearance AS (
    SELECT
        address,
        MIN(block_time) as first_seen
    FROM (
        SELECT topic1 as address, block_time
        FROM optimism.logs
        WHERE contract_address = 0x0000000000000000000000000000000000000000
        AND topic0 = 0x... -- DisputeInitiated

        UNION ALL

        SELECT topic2 as address, block_time
        FROM optimism.logs
        WHERE contract_address = 0x0000000000000000000000000000000000000000
        AND topic0 = 0x... -- DisputeInitiated
    ) all_participants
    GROUP BY 1
)
SELECT
    DATE_TRUNC('week', l.block_time) as week,
    COUNT(DISTINCT CASE WHEN fa.first_seen >= DATE_TRUNC('week', l.block_time) THEN l.topic1 END) as new_participants,
    COUNT(DISTINCT CASE WHEN fa.first_seen < DATE_TRUNC('week', l.block_time) THEN l.topic1 END) as returning_participants
FROM optimism.logs l
LEFT JOIN first_appearance fa ON l.topic1 = fa.address
WHERE l.contract_address = 0x0000000000000000000000000000000000000000
AND l.topic0 = 0x... -- DisputeInitiated
AND l.block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- DID Usage Rate
SELECT
    DATE_TRUNC('week', block_time) as week,
    COUNT(*) as did_associations,
    COUNT(DISTINCT topic1) as unique_disputes_with_did
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- DIDAssociatedWithDispute
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- ZK Mode Adoption
SELECT
    DATE_TRUNC('month', block_time) as month,
    COUNT(*) as zk_identity_registrations,
    COUNT(DISTINCT topic1) as unique_zk_disputes
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- ZKIdentityRegistered
GROUP BY 1
ORDER BY 1
