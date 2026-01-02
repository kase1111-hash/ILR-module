-- =============================================================================
-- ILRM Protocol - L3 Bridge Metrics Dashboard
-- =============================================================================
-- Platform: Dune Analytics
-- Network: Optimism (change to your deployed network)
-- =============================================================================

-- L3 Batch Submissions Over Time
SELECT
    DATE_TRUNC('day', block_time) as date,
    COUNT(*) as batches_submitted,
    SUM(CAST(SUBSTRING(data, 65, 32) AS UINT256)) as total_disputes_batched
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- L3Bridge address
AND topic0 = 0x... -- BatchSubmitted
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Batch Finalization Rate
SELECT
    DATE_TRUNC('week', block_time) as week,
    COUNT(CASE WHEN topic0 = 0x... THEN 1 END) as batches_submitted,
    COUNT(CASE WHEN topic0 = 0x... THEN 1 END) as batches_finalized,
    ROUND(
        100.0 * COUNT(CASE WHEN topic0 = 0x... THEN 1 END) /
        NULLIF(COUNT(CASE WHEN topic0 = 0x... THEN 1 END), 0),
        2
    ) as finalization_rate_pct
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 IN (0x..., 0x...) -- BatchSubmitted, BatchFinalized
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Challenge Statistics
SELECT
    COUNT(CASE WHEN topic0 = 0x... THEN 1 END) as challenges_initiated,
    COUNT(CASE WHEN topic0 = 0x... AND CAST(data AS BOOLEAN) = true THEN 1 END) as challenges_succeeded,
    COUNT(CASE WHEN topic0 = 0x... AND CAST(data AS BOOLEAN) = false THEN 1 END) as challenges_failed,
    ROUND(
        100.0 * COUNT(CASE WHEN topic0 = 0x... AND CAST(data AS BOOLEAN) = true THEN 1 END) /
        NULLIF(COUNT(CASE WHEN topic0 = 0x... THEN 1 END), 0),
        2
    ) as challenge_success_rate_pct
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 IN (0x..., 0x...) -- ChallengeInitiated, ChallengeResolved
AND block_time >= NOW() - INTERVAL '90' DAY

-- Average Batch Size
SELECT
    AVG(CAST(data AS UINT256)) as avg_disputes_per_batch,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(data AS UINT256)) as median_disputes_per_batch,
    MAX(CAST(data AS UINT256)) as max_batch_size
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- BatchSubmitted
AND block_time >= NOW() - INTERVAL '30' DAY

-- Batch Submitters Leaderboard
SELECT
    topic2 as submitter,
    COUNT(*) as batches_submitted,
    SUM(CAST(data AS UINT256)) as total_disputes_processed
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- BatchSubmitted
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 2 DESC
LIMIT 20

-- Time to Finalization (in blocks)
WITH batch_lifecycle AS (
    SELECT
        topic1 as batch_id,
        MIN(CASE WHEN topic0 = 0x... THEN block_number END) as submitted_block,
        MIN(CASE WHEN topic0 = 0x... THEN block_number END) as finalized_block
    FROM optimism.logs
    WHERE contract_address = 0x0000000000000000000000000000000000000000
    AND topic0 IN (0x..., 0x...) -- BatchSubmitted, BatchFinalized
    GROUP BY 1
)
SELECT
    AVG(finalized_block - submitted_block) as avg_blocks_to_finalize,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY finalized_block - submitted_block) as median_blocks,
    -- At ~2 seconds per block on Optimism
    AVG(finalized_block - submitted_block) * 2 / 3600 as avg_hours_to_finalize
FROM batch_lifecycle
WHERE finalized_block IS NOT NULL
AND submitted_block >= (SELECT MAX(block_number) - 1000000 FROM optimism.blocks)

-- Pending Batches (Not Yet Finalized)
SELECT
    topic1 as batch_id,
    topic2 as submitter,
    CAST(data AS UINT256) as dispute_count,
    block_time as submitted_at,
    (NOW() - block_time) as pending_duration
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- BatchSubmitted
AND topic1 NOT IN (
    SELECT topic1
    FROM optimism.logs
    WHERE contract_address = 0x0000000000000000000000000000000000000000
    AND topic0 = 0x... -- BatchFinalized
)
AND block_time >= NOW() - INTERVAL '14' DAY
ORDER BY block_time DESC
