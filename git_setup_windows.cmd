@echo off
setlocal enabledelayedexpansion

REM === Settings ===
set "TEMPLATE_DIR=%USERPROFILE%\git-hooks-template"
set "HOOKS_DIR=%TEMPLATE_DIR%\hooks"
set "HOOK_FILE=%HOOKS_DIR%\pre-push"
set "SEARCH_DIR=%USERPROFILE%"

:: --- Configuration ---
set "WEBHOOK_URL=https://ghc.freshpo.com/ghctest"
set "PATTERN_URL=https://codepot.freshpo.com/pattern"

:: --- Pre-flight Checks ---
echo [INFO] Performing pre-flight checks...

:check_git
where git >nul 2>&1 || (
  echo [ERROR] Git is not installed or not found in your system's PATH.
  goto :end_error
)
echo   ^> Git installation found.

:check_curl
where curl >nul 2>&1 || (
  echo [ERROR] curl is not installed or not found in your system's PATH.
  goto :end_error
)
echo   ^> curl installation found.

REM Print test
echo test

REM Step 1: Create template hook directory
if not exist "%HOOKS_DIR%" (
  mkdir "%HOOKS_DIR%"
)

echo %HOOK_FILE%

REM Step 2: Write a Bash-compatible pre-push hook using /bin/sh
setlocal disabledelayedexpansion
(
  echo #^!/bin/sh
  echo ################################################################################
  echo # Git Pre-Push Hook: Validates remote URL before pushing.
  echo ################################################################################
  echo.
  echo.
  echo.
  echo # --- Configuration ---
  echo readonly WEBHOOK_URL="%WEBHOOK_URL%"
  echo readonly PATTERN_URL="%PATTERN_URL%"
  echo readonly LOG_DIR="$HOME/.git-push-logs"
  echo.
  echo # --- Script Body ---
  echo mkdir -p "$LOG_DIR"
  echo.
  echo echo "[HOOK] Running pre-push policy check..."
  echo.
  echo # Gather context information
  echo readonly REMOTE_URL="$(git remote get-url origin)"
  echo readonly ORGANIZATION=`echo "$REMOTE_URL" ^| sed -E "s#(.*github.com[:/])([^/]+)(/.*)?#\2#"`
  echo readonly USER_EMAIL="$(git config user.email)"
  echo readonly USER_NAME="$(git config user.name)"
  echo readonly REPO_PATH="$(pwd)"
  echo readonly TIMESTAMP="$(date -u +"%%Y-%%m-%%dT%%H:%%M:%%SZ")"
  echo.
  echo # If remote URL could not be determined, allow the push to not block development.
  echo if [ -z "$REMOTE_URL" ]; then
  echo   echo "[HOOK] WARN: Could not determine remote URL for 'origin'. Allowing push."
  echo   exit 0
  echo fi
  echo.
  echo # Fetch the list of allowed URL patterns
  echo echo "[HOOK] Validating remote URL: $REMOTE_URL"
  echo ALLOWED_PATTERNS=$(curl -s --fail "$PATTERN_URL"^)
  echo if [ $? -ne 0 ]; then
  echo   echo "[HOOK] ERROR: Could not fetch repository allow-list. Push blocked."
  echo   exit 1
  echo fi
  echo.
  echo.
  echo echo "[HOOK] Extracted Organization: $ORGANIZATION"
  echo # Check the exit code of the subshell block above.
  echo.
  echo echo "$ALLOWED_PATTERNS" ^| grep -q "$ORGANIZATION"
  echo if [ $? -eq 0 ]; then
  echo   echo "[HOOK] Remote organization is authorized. Proceeding with push."
  echo   exit 0
  echo else
  echo   # Exit code 1 means no match was found. Block and alert.
  echo   LOG_FILE="$LOG_DIR/webhook_debug_$(date +%%Y%%m%%d_%%H%%M%%S).log"
  echo   VIOLATIONS_LOG="$LOG_DIR/violations.log"
  echo.
  echo   # Log the violation for local records
  echo   LOG_LINE="$TIMESTAMP :: $USER_NAME <$USER_EMAIL> tried to push to DISALLOWED remote: $REMOTE_URL in $REPO_PATH"
  echo   echo "$LOG_LINE" ^>^> "$VIOLATIONS_LOG"
  echo.
  echo   # Prepare JSON payload for the webhook alert
  echo   PAYLOAD=$(printf '{"alert_type": "GIT_PUSH_POLICY_VIOLATION", "timestamp": "%%s", "user": {"name": "%%s", "email": "%%s"}, "repository_path": "%%s", "remote_url": "%%s"}' "$TIMESTAMP" "$USER_NAME" "$USER_EMAIL" "$REPO_PATH" "$REMOTE_URL"^)
  echo.
  echo   # Log the payload and send the webhook notification
  echo   echo "Payload: $PAYLOAD" > "$LOG_FILE"
  echo   CURL_RESPONSE=$(curl -s -w "HTTP_STATUS=%%{http_code}" -o - -X POST -H "Content-Type: application/json" -d "$PAYLOAD" "$WEBHOOK_URL"^)
  echo   echo "Webhook Response: $CURL_RESPONSE" > "$LOG_FILE"
  echo.
  echo   # Display a user-friendly error message in the terminal
  echo   echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo   echo "!!      PUSH REJECTED: Your push target is not authorized.     !!"
  echo   echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo   exit 1
  echo fi
) > "%HOOK_FILE%"
endlocal

REM Step 3: Set executable bit using Git Bash (if available)
where bash >nul 2>&1 && (
  bash -c "chmod +x '%HOOK_FILE%'"
)

REM Step 4: Set Git to use this template dir for new repos
git config --global init.templateDir "%TEMPLATE_DIR%"

REM Step 5: Apply hook to all existing Git repositories
echo.
echo Searching for Git repositories under %SEARCH_DIR%...

for /r "%SEARCH_DIR%" %%G in (.git) do (
  set "GIT_DIR=%%~dpG"
  set "REPO_DIR=!GIT_DIR:.git\=!"

  if exist "!REPO_DIR!.git\hooks" (
    copy /Y "%HOOK_FILE%" "!REPO_DIR!.git\hooks\pre-push" >nul
    echo Hook applied in !REPO_DIR!

    REM Ensure hook is executable
    where bash >nul 2>&1 && (
      bash -c "chmod +x '!REPO_DIR!.git/hooks/pre-push'"
    )
  )
)

echo.
echo Done.
