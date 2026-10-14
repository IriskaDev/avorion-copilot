# 构建 dsh-avorion-copilot。
#
# 本机没有 DSH 源码 checkout（没有 packages/ 与 vendor/），所以：
#   * 类型来自全局安装的 npm 包 @deepseek-ai/dsh-llm（它自带 .d.ts）
#   * tsc 借用另一个插件工程 node_modules.bak 里的那份
#
# ⚠️ 关键：编译需要 node_modules 链接，但**产物绝不能带着它们**。
# DSH 宿主会自己解析 @deepseek-ai/* 与 schemastery（已装且能工作的 dsh-global-memory
# 与 dsh-cosplay 都没有自己的 node_modules）。插件自带 node_modules 反而会**遮蔽**宿主
# 那份，而 npm 版 dsh-llm 的传递依赖 @deepseek-ai/cordis 是个空目录，会直接加载失败。
#
# 所以流程是：建链接 → 编译 → 删链接。跑完插件目录是干净的。
#
# 用法： pwsh -File scripts/build.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$dshModules = 'C:\nvm4w\nodejs\node_modules\@deepseek-ai\dsh\node_modules'
$tsc = 'D:\workbench\projects\dsh\dsh-global-memory\node_modules.bak\.bin\tsc.cmd'
$nm = Join-Path $root 'node_modules'

if (-not (Test-Path $tsc)) { throw "找不到 tsc：$tsc" }
if (-not (Test-Path "$dshModules\@deepseek-ai\dsh-llm")) { throw "找不到 dsh-llm：$dshModules" }
if (-not (Test-Path "$dshModules\@deepseek-ai\dsh-tools")) { throw "找不到 dsh-tools：$dshModules" }

function Clear-Links {
  if (Test-Path -LiteralPath $nm) {
    # 逐个删链接（rmdir 只删链接本身，不动目标），再删空目录
    foreach ($p in @("$nm\@deepseek-ai\dsh-llm", "$nm\@deepseek-ai\dsh-tools", "$nm\@types\node")) {
      if (Test-Path -LiteralPath $p) { cmd /c rmdir "$p" | Out-Null }
    }
    Remove-Item $nm -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host '=== 建立编译期依赖链接 ==='
Clear-Links
New-Item -ItemType Directory -Force -Path "$nm\@deepseek-ai", "$nm\@types" | Out-Null
New-Item -ItemType Junction -Path "$nm\@deepseek-ai\dsh-llm" -Target "$dshModules\@deepseek-ai\dsh-llm" | Out-Null
New-Item -ItemType Junction -Path "$nm\@deepseek-ai\dsh-tools" -Target "$dshModules\@deepseek-ai\dsh-tools" | Out-Null
New-Item -ItemType Junction -Path "$nm\@types\node" -Target "$dshModules\@types\node" | Out-Null

try {
  Write-Host '=== 编译 src -> lib ==='
  & $tsc -p tsconfig.json
  if ($LASTEXITCODE -ne 0) { throw "tsc 失败（exit $LASTEXITCODE）" }
} finally {
  Write-Host '=== 清理编译期链接（运行时由宿主解析）==='
  Clear-Links
}

Write-Host '=== 完成 ==='
Get-ChildItem (Join-Path $root 'lib') -Recurse -File | ForEach-Object {
  Write-Host ("  {0}  {1} bytes" -f $_.FullName.Replace("$root\", ''), $_.Length)
}
