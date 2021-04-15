set EXTRA_ARGS=

@REM TODO: option to enable/disable unicode?
EXTRA_ARGS=%EXTRA_ARGS% /D_UNICODE /DUNICODE

@if not exist out mkdir out
@if not exist out\obj mkdir out\obj
@if not exist out\bin mkdir out\bin
cl /Fo.\out\obj\ /Feout\bin\wrc-client.exe %EXTRA_ARGS% /DWIN32 /D_WINDOWS wrc-client.cpp common.cpp
