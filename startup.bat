@echo off
REM ============================================================================
REM NatLangChain ILRM Protocol - Startup Script (Windows)
REM ============================================================================
REM This script starts a local development environment
REM ============================================================================

setlocal enabledelayedexpansion

echo.
echo ============================================
echo   NatLangChain ILRM - Development Startup
echo ============================================
echo.

REM Parse command line arguments
set MODE=anvil
set FORK=
set DEPLOY=false

:parse_args
if "%~1"=="" goto end_parse
if /i "%~1"=="--hardhat" set MODE=hardhat
if /i "%~1"=="--anvil" set MODE=anvil
if /i "%~1"=="--fork-mainnet" set FORK=mainnet
if /i "%~1"=="--fork-optimism" set FORK=optimism
if /i "%~1"=="--fork-sepolia" set FORK=sepolia
if /i "%~1"=="--deploy" set DEPLOY=true
if /i "%~1"=="--help" goto show_help
shift
goto parse_args
:end_parse

REM Show help if requested
goto skip_help
:show_help
echo Usage: startup.bat [OPTIONS]
echo.
echo Options:
echo   --anvil          Use Anvil (Foundry) as local node (default)
echo   --hardhat        Use Hardhat Network as local node
echo   --fork-mainnet   Fork Ethereum mainnet
echo   --fork-optimism  Fork Optimism mainnet
echo   --fork-sepolia   Fork Sepolia testnet
echo   --deploy         Deploy contracts after starting node
echo   --help           Show this help message
echo.
echo Examples:
echo   startup.bat                        Start Anvil locally
echo   startup.bat --hardhat              Start Hardhat node
echo   startup.bat --fork-optimism        Fork Optimism mainnet
echo   startup.bat --deploy               Start Anvil and deploy contracts
echo.
exit /b 0
:skip_help

REM Check dependencies
echo [1/4] Checking dependencies...

if "%MODE%"=="anvil" (
    where anvil >nul 2>&1
    if %errorlevel% neq 0 (
        echo [ERROR] Anvil not found. Please install Foundry.
        echo   Run: curl -L https://foundry.paradigm.xyz ^| bash
        echo   Then: foundryup
        exit /b 1
    )
    echo       Anvil found
) else (
    where npx >nul 2>&1
    if %errorlevel% neq 0 (
        echo [ERROR] Node.js/npx not found.
        exit /b 1
    )
    echo       Hardhat found
)

REM Check if contracts are compiled
echo.
echo [2/4] Checking build artifacts...
if not exist "out" (
    echo       No build found. Running assembly...
    call assemble.bat
    if %errorlevel% neq 0 (
        echo [ERROR] Assembly failed
        exit /b 1
    )
) else (
    echo       Build artifacts found
)

REM Build command
echo.
echo [3/4] Preparing environment...

if "%MODE%"=="anvil" (
    set CMD=anvil
    set CMD=!CMD! --host 0.0.0.0
    set CMD=!CMD! --port 8545
    set CMD=!CMD! --accounts 10
    set CMD=!CMD! --balance 10000

    if "%FORK%"=="mainnet" (
        if defined ETH_RPC_URL (
            set CMD=!CMD! --fork-url %ETH_RPC_URL%
            echo       Forking Ethereum Mainnet...
        ) else (
            echo [WARN] ETH_RPC_URL not set. Starting without fork.
        )
    )
    if "%FORK%"=="optimism" (
        if defined OPTIMISM_RPC_URL (
            set CMD=!CMD! --fork-url %OPTIMISM_RPC_URL%
            echo       Forking Optimism Mainnet...
        ) else (
            echo [WARN] OPTIMISM_RPC_URL not set. Starting without fork.
        )
    )
    if "%FORK%"=="sepolia" (
        if defined SEPOLIA_RPC_URL (
            set CMD=!CMD! --fork-url %SEPOLIA_RPC_URL%
            echo       Forking Sepolia Testnet...
        ) else (
            echo [WARN] SEPOLIA_RPC_URL not set. Starting without fork.
        )
    )
) else (
    set CMD=npx hardhat node
)

echo       Mode: %MODE%
if not "%FORK%"=="" echo       Fork: %FORK%

REM Start the node
echo.
echo [4/4] Starting local node...
echo.
echo ============================================
echo   Local Development Node
echo ============================================
echo.
echo   RPC URL: http://localhost:8545
echo   Chain ID: 31337
echo.
echo   Press Ctrl+C to stop the node
echo.
echo ============================================
echo.

if "%DEPLOY%"=="true" (
    echo Starting node in background and deploying contracts...
    start /b !CMD!
    timeout /t 5 /nobreak >nul
    echo.
    echo Deploying contracts...
    call npx hardhat run scripts/deploy.js --network localhost
    echo.
    echo Contracts deployed. Node still running.
    echo Press Ctrl+C to stop.
    pause >nul
) else (
    !CMD!
)

endlocal
