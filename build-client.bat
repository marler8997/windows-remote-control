set EXTRA_ARGS=

@REM TODO: option to enable/disable unicode?
EXTRA_ARGS=%EXTRA_ARGS% /D_UNICODE /DUNICODE

cl %EXTRA_ARGS% /DWIN32 /D_WINDOWS wrc-client.cpp common.cpp
