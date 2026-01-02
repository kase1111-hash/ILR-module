-- =============================================================================
-- ILRM Protocol - Financial Metrics Dashboard
-- =============================================================================
-- Platform: Dune Analytics
-- Network: Optimism (change to your deployed network)
-- =============================================================================

-- Total Value Staked (TVL)
SELECT
    SUM(CAST(data AS UINT256)) / 1e18 as total_staked_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Replace with ILRM address
AND topic0 = 0x... -- StakeDeposited event signature

-- Total Value Burned
SELECT
    SUM(CAST(data AS UINT256)) / 1e18 as total_burned_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Replace with ILRM address
AND topic0 = 0x... -- StakesBurned event signature

-- Daily Stake/Burn Volume
SELECT
    DATE_TRUNC('day', block_time) as date,
    SUM(CASE WHEN topic0 = 0x... THEN CAST(data AS UINT256) / 1e18 ELSE 0 END) as staked_eth,
    SUM(CASE WHEN topic0 = 0x... THEN CAST(data AS UINT256) / 1e18 ELSE 0 END) as burned_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 IN (0x..., 0x...) -- StakeDeposited, StakesBurned
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Treasury Balance Over Time
SELECT
    DATE_TRUNC('day', block_time) as date,
    SUM(SUM(CASE
        WHEN topic0 = 0x... THEN CAST(data AS UINT256) / 1e18
        WHEN topic0 = 0x... THEN -CAST(data AS UINT256) / 1e18
        ELSE 0
    END)) OVER (ORDER BY DATE_TRUNC('day', block_time)) as cumulative_balance
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Treasury address
AND topic0 IN (0x..., 0x...) -- TreasuryReceived, SubsidyFunded
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Counter-Proposal Fees Collected
SELECT
    DATE_TRUNC('week', block_time) as week,
    COUNT(*) as counter_count,
    SUM(CAST(data AS UINT256)) / 1e18 as fees_collected_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- ILRM address
AND topic0 = 0x... -- CounterProposed event signature
AND block_time >= NOW() - INTERVAL '90' DAY
GROUP BY 1
ORDER BY 1

-- Average Stake Size
SELECT
    AVG(CAST(data AS UINT256)) / 1e18 as avg_stake_eth,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(data AS UINT256) / 1e18) as median_stake_eth,
    MIN(CAST(data AS UINT256)) / 1e18 as min_stake_eth,
    MAX(CAST(data AS UINT256)) / 1e18 as max_stake_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000
AND topic0 = 0x... -- StakeDeposited
AND block_time >= NOW() - INTERVAL '30' DAY

-- Subsidy Distribution by Reason
SELECT
    -- Extract reason from event data (assuming it's indexed or in data)
    CASE
        WHEN data LIKE '%dispute_refund%' THEN 'Dispute Refund'
        WHEN data LIKE '%first_time_bonus%' THEN 'First-Time Bonus'
        WHEN data LIKE '%low_sybil_bonus%' THEN 'Low Sybil Bonus'
        ELSE 'Other'
    END as reason,
    COUNT(*) as count,
    SUM(CAST(SUBSTRING(data, 1, 32) AS UINT256)) / 1e18 as total_eth
FROM optimism.logs
WHERE contract_address = 0x0000000000000000000000000000000000000000 -- Treasury address
AND topic0 = 0x... -- SubsidyFunded
AND block_time >= NOW() - INTERVAL '30' DAY
GROUP BY 1
ORDER BY 3 DESC
