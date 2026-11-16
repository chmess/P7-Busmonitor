$P7HttpPort=8088
$EspaHttpPort=8765
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$data=Join-Path $here 'data'
[void][IO.Directory]::CreateDirectory($data)
$ps=Join-Path $PSHOME 'powershell.exe'
$children=@()
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$p7Out=Join-Path $data ('P7-'+$stamp+'.log')
$p7Err=Join-Path $data ('P7-'+$stamp+'.error.log')
$espaOut=Join-Path $data ('ESPA-'+$stamp+'.log')
$espaErr=Join-Path $data ('ESPA-'+$stamp+'.error.log')
$p7Url='http://127.0.0.1:'+$P7HttpPort+'/'
$espaUrl='http://127.0.0.1:'+$EspaHttpPort+'/'
try{
    Write-Host 'P7-Busmonitor startet ohne Installation und ohne Administratorrechte.' -ForegroundColor Cyan
    $p7Args='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $here 'P7/P7Monitor.ps1')+'" -HttpPort '+$P7HttpPort
    $p7=Start-Process -FilePath $ps -ArgumentList $p7Args -PassThru -WindowStyle Hidden -RedirectStandardOutput $p7Out -RedirectStandardError $p7Err
    $children+=,$p7
    $espaArgs='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $here 'ESPA/ESPA.ps1')+'" -HttpPort '+$EspaHttpPort+' -NoBrowser'
    $espa=Start-Process -FilePath $ps -ArgumentList $espaArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $espaOut -RedirectStandardError $espaErr
    $children+=,$espa
    Start-Sleep -Seconds 2
    foreach($child in $children){$child.Refresh();if($child.HasExited){throw ('Ein Teilserver wurde beendet. Siehe data-Logdateien. Prozess-ID: '+$child.Id)}}
    Write-Host ('P7-Monitor: '+$p7Url) -ForegroundColor Green
    Write-Host ('ESPA 4.4.4: '+$espaUrl) -ForegroundColor Green
    Write-Host 'Zum Beenden dieses Fenster schließen oder Strg+C drücken.' -ForegroundColor Yellow
    Start-Process $p7Url
    while($true){
        Start-Sleep -Seconds 1
        foreach($child in $children){$child.Refresh();if($child.HasExited){throw ('Ein Teilserver wurde beendet. Siehe data-Logdateien. Prozess-ID: '+$child.Id)}}
    }
}catch{
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ('Protokolle: '+$data) -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}finally{
    foreach($child in $children){try{$child.Refresh();if(-not $child.HasExited){Stop-Process -Id $child.Id -Force}}catch{}}
}
