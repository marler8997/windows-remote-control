@if not exist out mkdir out
@if not exist out\obj mkdir out\obj
@if not exist out\bin mkdir out\bin

cl /Fo.\out\obj\ /Feout\bin\wrc-server.exe wrc-server.cpp common.cpp
