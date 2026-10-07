param([string]$OutputDirectory=$PSScriptRoot)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$compileDir=Join-Path $env:TEMP ('ITaiwanBuild-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $compileDir | Out-Null
try{
 $output=Join-Path $compileDir 'ITaiwan.exe'
 $parameters=[CodeDom.Compiler.CompilerParameters]::new()
 $parameters.GenerateExecutable=$true;$parameters.OutputAssembly=$output;$parameters.CompilerOptions='/target:winexe'
 foreach($assembly in @('System.dll','System.Core.dll','System.Windows.Forms.dll')){[void]$parameters.ReferencedAssemblies.Add($assembly)}
 foreach($name in @('Wifi.cs','Core.ps1','Auth.ps1','Portal.ps1','AppCore.ps1','ITaiwan.ps1','Tray.ps1','Manage.ps1','README.md')){[void]$parameters.EmbeddedResources.Add((Join-Path $PSScriptRoot $name))}
 Add-Type -Path (Join-Path $PSScriptRoot 'Launcher.cs') -CompilerParameters $parameters
 Copy-Item $output (Join-Path $OutputDirectory 'ITaiwan.exe') -Force
 Copy-Item $output (Join-Path $OutputDirectory 'Setup.exe') -Force
 Write-Host 'Built native supervisor and packaged runtime.'
}finally{Remove-Item $compileDir -Recurse -Force -ErrorAction SilentlyContinue}
