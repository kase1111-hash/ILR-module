@echo off
echo ========================================
echo   ILRM Module Build Script
echo ========================================
echo.

:: Check for Foundry
where forge >nul 2>nul
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Foundry not found. Install from https://getfoundry.sh
    echo   Run: curl -L https://foundry.paradigm.xyz ^| bash
    pause
    exit /b 1
)

:: Install Foundry dependencies
echo [1/3] Installing Foundry dependencies...
forge install --no-commit
if %ERRORLEVEL% neq 0 (
    echo [WARN] forge install had issues, continuing...
)

:: Install npm dependencies (optional, for Hardhat)
where npm >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo [2/3] Installing npm dependencies...
    npm install
) else (
    echo [2/3] Skipping npm install (Node.js not found)
)

:: Build contracts
echo [3/3] Building contracts...
forge build
if %ERRORLEVEL% neq 0 (
    echo.
    echo [ERROR] Build failed!
    pause
    exit /b 1
)

echo.
echo ========================================
echo   Build completed successfully!
echo ========================================
echo.
echo To run tests: forge test
echo To run with verbose: forge test -vvv
echo.
pause
