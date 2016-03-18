@echo off
cd "%~dp0"

if exist temp rmdir /S /Q temp
mkdir temp

java -jar lib\dsl-clc.jar ^
  download ^
  temp=temp ^
  "postgres=localhost:5432/animals_db?user=animals_user&password=animals_pass" ^
  apply
