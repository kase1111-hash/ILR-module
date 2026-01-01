@echo off
REM ============================================================================
REM NatLangChain ILRM Protocol - Assembly Script (Windows)
REM ============================================================================
REM This script compiles all smart contracts using Foundry and Hardhat
REM ============================================================================

setlocal enabledelayedexpansion

echo.
echo ============================================
echo   NatLangChain ILRM - Contract Assembly
echo ============================================
echo.

REM Check if Foundry is installed
where forge >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Foundry not found. Please install from https://getfoundry.sh/
    echo   Run: curl -L https://foundry.paradigm.xyz ^| bash
    echo   Then: foundryup
    exit /b 1
)

REM Check if Node.js is installed
where node >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Node.js not found. Please install from https://nodejs.org/
    exit /b 1
)

echo [1/5] Checking dependencies...
if not exist "node_modules" (
    echo       Installing npm dependencies...
    call npm install
    if %errorlevel% neq 0 (
        echo [ERROR] npm install failed
        exit /b 1
    )
)

if not exist "lib" (
    echo       Installing Foundry dependencies...
    call forge install
    if %errorlevel% neq 0 (
        echo [ERROR] forge install failed
        exit /b 1
    )
)
echo       Dependencies OK

echo.
echo [2/5] Cleaning previous builds...
if exist "out" rmdir /s /q out
if exist "cache" rmdir /s /q cache
if exist "artifacts" rmdir /s /q artifacts
echo       Clean complete

echo.
echo [3/5] Compiling with Foundry...
call forge build
if %errorlevel% neq 0 (
    echo [ERROR] Foundry compilation failed
    exit /b 1
)
echo       Foundry build successful

echo.
echo [4/5] Compiling with Hardhat...
call npx hardhat compile
if %errorlevel% neq 0 (
    echo [ERROR] Hardhat compilation failed
    exit /b 1
)
echo       Hardhat build successful

echo.
echo [5/5] Checking contract sizes...
call forge build --sizes 2>&1 | findstr /i "contract"
echo.

echo ============================================
echo   Assembly Complete!
echo ============================================
echo.
echo   Foundry artifacts: ./out/
echo   Hardhat artifacts: ./artifacts/
echo.
echo   Next steps:
echo   - Run tests: forge test
echo   - Start local node: startup.bat
echo   - Deploy: npm run deploy:sepolia
echo.

endlocal
