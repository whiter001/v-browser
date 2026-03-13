# 创建目录
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.config\v-browser"

# 创建配置文件
@"
V_BROWSER_EXTENSION_ID=eefgklfpdnjodmmjefedjfnflacaimmj
V_BROWSER_BROWSER_APP=C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe
"@ | Out-File -FilePath "$env:USERPROFILE\.config\v-browser\config" -Encoding UTF8