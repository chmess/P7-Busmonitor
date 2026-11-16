param([int]$HttpPort = 8088)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System
$script:root = $PSScriptRoot
$script:dataDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'data'
[void][IO.Directory]::CreateDirectory($script:dataDir)
$script:configPath = Join-Path $script:dataDir 'config.json'
$script:cfg = [ordered]@{
    port='COM3'; baud=115200; stale_seconds=180; offline_seconds=600
    quiet_warn_seconds=10; quiet_critical_seconds=60; reply_timeout_seconds=3
    capture=$true
    group_types=[ordered]@{
        '3'=@{label='RT-AT-P7';catalog_id='HP70575'}
        '4'=@{label='RT-P7';catalog_id='HP70610'}
        '15'=@{label='PNEU-P7';catalog_id='HP70690'}
        '17'=@{label='ZT-AT-P7';catalog_id='HP70685'}
        '19'=@{label='ZL-P7';catalog_id=''}
        '21'=@{label='RT-NS-P7';catalog_id='HP70565'}
        '27'=@{label='DM-P7';catalog_id=''}
        '47'=@{label='ZT70-D2T';catalog_id='300526'}
        '50'=@{label='ZM71';catalog_id=''}
        '70'=@{label='IO8-P7';catalog_id=''}
    }
}
if(Test-Path $script:configPath){
    try { $saved=Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json; foreach($prop in $saved.PSObject.Properties){$script:cfg[$prop.Name]=$prop.Value} } catch { Write-Warning ('Konfiguration konnte nicht geladen werden: '+$_.Exception.Message) }
}
$script:knownStatuses=@{
 '0B 00 07'='Ruhezustand';'03 07 07'='Ruf / Alarm';'05 0E 07'='Anwesend'
 '02 0A 07'='Notruf';'05 01 01'='Störung';'05 0E 01'='Anwesend'
 '03 07 05'='Ruf';'03 09 05'='WC-Ruf';'02 0A 05'='Notruf'
 '03 07 01'='Ruf';'03 09 01'='WC-Ruf';'02 0A 01'='Notruf';'02 0B 01'='WC-Not'
}
$script:devices=@{}; $script:targets=@{}; $script:children=@{}
$script:events=[System.Collections.Generic.List[object]]::new()
$script:telemetry=[System.Collections.Generic.List[object]]::new()
$script:buffer=[System.Collections.Generic.List[byte]]::new()
$script:bus=$null
$script:serial=$null; $script:running=$false; $script:portError=''
$script:lastBusRx=$null; $script:resetAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
$script:captureBin=$null; $script:captureJson=$null; $script:captureFile=''
$script:playbackRows=@(); $script:playbackNextAt=[DateTime]::UtcNow
$script:playback=[ordered]@{state='idle';file='';index=0;total=0;speed=1.0;source_time=$null;start_time=$null;end_time=$null;markers=@()}
function New-BusCounters {
    return [ordered]@{frames=0;valid_frames=0;bytes=0;checksum_errors=0;errors=0;station_fault_reports=0;unframed=0;polls_without_reply=0;messages_without_ack=0;repetitions=0;disconnects=0;malformed=0;unknown=0;quiet_gaps=0;longest_gap_seconds=0;master_request_candidates=0}
}
$script:bus=New-BusCounters
function Get-Now {
    if($null -ne $script:playback.source_time -and $script:playback.state -in @('playing','paused','finished')){return [double]$script:playback.source_time}
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
}
function Add-Telemetry($device,[string]$kind,$value=1){
    $script:telemetry.Add(@{time=(Get-Now);device=[string]$device;kind=$kind;value=$value})
    while($script:telemetry.Count -gt 30000){$script:telemetry.RemoveAt(0)}
}
function Write-CaptureLine($row){
    if($script:captureJson){$line=ConvertTo-Json -InputObject $row -Depth 15 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($line+[Environment]::NewLine);$script:captureJson.Write($bytes,0,$bytes.Length);$script:captureJson.Flush()}
}
function Add-Event([string]$kind,[string]$message,[string]$device='',[string]$raw='',$details=$null){
    $e=[ordered]@{time=(Get-Now);kind=$kind;message=$message;device=$(if($device){$device}else{$null});raw=$raw}
    if($details){foreach($p in $details.GetEnumerator()){$e[$p.Key]=$p.Value}}
    $script:events.Insert(0,$e);while($script:events.Count -gt 500){$script:events.RemoveAt($script:events.Count-1)}
    if($kind -in @('error','unknown','malformed')){Add-Telemetry $(if($device){$device}else{'Bus'}) $kind 1}
    if($kind -eq 'marker' -and $script:captureJson){Write-CaptureLine @{type='marker';time=(Get-Now);message=$message}}
}
function Reset-Metrics {
    $script:devices.Clear();$script:targets.Clear();$script:children.Clear();$script:events.Clear();$script:telemetry.Clear();$script:buffer.Clear()
    $script:bus=New-BusCounters;$script:lastBusRx=$null
    $script:resetAt=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
    Add-Event 'marker' 'Messzähler auf 0 gesetzt'
}
function Start-Capture {
    if(-not $script:cfg.capture){return}
    $tag=Get-Date -Format 'yyyyMMdd_HHmmss'
    $base=Join-Path $script:dataDir ('p7_'+$tag)
    $script:captureFile=$tag
    $script:captureBin=[IO.File]::Open($base+'.bin',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $script:captureJson=[IO.File]::Open($base+'.jsonl',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
}
function Stop-Capture {
    if($script:captureBin){$script:captureBin.Dispose();$script:captureBin=$null}
    if($script:captureJson){$script:captureJson.Dispose();$script:captureJson=$null}
}
function Start-Monitor {
    if($script:running){return}
    if($script:playback.state -in @('playing','paused')){throw 'Wiedergabe zuerst stoppen'}
    $port=[string]$script:cfg.port
    $baud=[int]$script:cfg.baud
    if($port -notmatch '^COM[0-9]+$'){throw 'COM-Port muss z. B. COM3 lauten'}
    $sp=[IO.Ports.SerialPort]::new($port,$baud,[IO.Ports.Parity]::None,8,[IO.Ports.StopBits]::One)
    $sp.ReadTimeout=1
    $sp.Open()
    $script:serial=$sp;$script:running=$true;$script:portError=''
    Start-Capture
    Add-Event 'info' ('Mitschnitt gestartet: '+$port+' @ '+$baud+' 8N1')
}
function Stop-Monitor {
    $script:running=$false
    if($script:serial){try{$script:serial.Close();$script:serial.Dispose()}catch{};$script:serial=$null}
    Stop-Capture
    Add-Event 'info' 'Mitschnitt gestoppt'
}
function Canonical-Id([string]$id){
    $parts=$id.Split('-');if($parts.Count -ne 2){return $id}
    try{return ([int]$parts[0]).ToString()+'-'+([int]$parts[1]).ToString()}catch{return $id}
}
function Find-Sync([byte[]]$data){
    for($i=0;$i -lt $data.Length-1;$i++){
        if(($data[$i] -eq 0x55 -and $data[$i+1] -in @(0x55,0xAA)) -or ($data[$i] -eq 0xAA -and $data[$i+1] -eq 0x55)){return $i}
    }
    return -1
}
function Decode-Text([byte[]]$data,[int]$offset,[int]$count,[int]$encoding=437){
    if($offset -ge $data.Length){return ''}
    $take=[Math]::Min($count,$data.Length-$offset);$end=$offset
    while($end -lt ($offset+$take) -and $data[$end] -ne 0){$end++}
    if($end -le $offset){return ''}
    try{return [Text.Encoding]::GetEncoding($encoding).GetString($data,$offset,$end-$offset).Trim()}catch{return [Text.Encoding]::ASCII.GetString($data,$offset,$end-$offset).Trim()}
}
function Get-Signal([byte[]]$f){
    if($f.Length -lt 12 -or (($f[6] -ne 1 -or $f[7] -ne 4) -and ($f[6] -ne 2 -or $f[7] -ne 4))){return $null}
    $mode=[int]$f[8];$code=if($mode -eq 1 -or $mode -eq 4){[int]$f[9]}elseif($mode -eq 0){[int]$f[10]}else{-1}
    $names=@{7='Ruf';9='WC-Ruf';10='Notruf';14='Anwesenheit'}
    if(-not $names.ContainsKey($code)){return $null}
    $active=if($mode -eq 1){$true}elseif($mode -eq 0){$false}else{$null}
    $label=if($code -eq 14 -and $null -ne $active){if($active){'Anwesend'}else{'Abwesend'}}elseif($active -eq $false){$names[$code]+' beendet'}elseif($null -eq $active){$names[$code]+': Sonderzustand 04'}else{$names[$code]}
    return @{code=('{0:X2}' -f $code);name=$names[$code];active=$active;mode=$mode;label=$label}
}
function Get-Status([string]$key){
    if($script:knownStatuses.ContainsKey($key)){return $script:knownStatuses[$key]}
    if($script:cfg.known_statuses){$v=$script:cfg.known_statuses.PSObject.Properties[$key];if($v){return [string]$v.Value}}
    return ''
}
function Add-Device([string]$id){
    if(-not $script:devices.ContainsKey($id)){
        $script:devices[$id]=[ordered]@{id=$id;name='';count=0;errors=@{checksum=0;unknown=0};repetitions=0;polls_without_reply=0;messages_without_ack=0;last_seen=0;age=$null;state='offline';last_status='';reported_status='';reported_status_time=0;history=[System.Collections.Generic.List[object]]::new();types=@{};signals=@{};seen_frames=@{};repeat_streak=0;last_signature=''}
    }
    return $script:devices[$id]
}
function Get-HexSlice([byte[]]$bytes,[int]$start,[int]$end){
    if($start -lt 0){$start=0}
    if($end -ge $bytes.Length){$end=$bytes.Length-1}
    if($start -gt $end -or $start -ge $bytes.Length){return ''}
    return (($bytes[$start..$end]|%{$_.ToString('X2')}) -join ' ')
}
function Decode-Frame([byte[]]$f){
    if($f.Length -lt 8){$script:bus.malformed++;Add-Event 'malformed' 'Telegramm zu kurz' '' (($f|%{$_.ToString('X2')}) -join ' ');return}
    $len=[int]$f[2];$id=([int]$f[3]).ToString()+'-'+([int]($f[4]*256+$f[5])).ToString()
    $sync=($f[0..1]|%{$_.ToString('X2')}) -join ' '
    $command=('{0:X2} {1:X2}' -f $f[6],$f[7])
    $sum=0;for($i=0;$i -lt $f.Length-1;$i++){$sum+=[int]$f[$i]}
    $expected=(255-($sum%255))%255
    $checksumOk=($len -eq $f.Length -and [int]$f[$f.Length-1] -eq $expected)
    $statusKey='';$status=''
    if($command -eq '01 03' -and $f.Length -ge 17){$statusKey=($f[14..16]|%{$_.ToString('X2')}) -join ' ';$status=Get-Status $statusKey}
    $signal=if($checksumOk){Get-Signal $f}else{$null}
    $central=$null
    if($checksumOk -and $f.Length -eq 41 -and $sync -eq 'AA 55' -and $f[7] -eq 3){
        $target=([int]$f[11]).ToString()+'-'+([int]($f[12]*256+$f[13])).ToString()
        $code=($f[14..16]|%{$_.ToString('X2')}) -join ' '
        $name=Decode-Text $f 17 13 437;$label=Decode-Text $f 30 10 437
        $kindMap=@{'05 01'='fault';'05 0E'='presence';'03 07'='call';'03 09'='bath_call';'02 0A'='emergency';'02 0B'='emergency'}; $prefix=$code.Substring(0,5);$kindName=if($kindMap.ContainsKey($prefix)){$kindMap[$prefix]}else{'other'}
        $channel='';if($name.StartsWith($target+'-')){$tail=$name.Substring($target.Length+1);if($tail -match '^[0-9]+$'){$channel=$tail}}
        $central=@{target=$target;code=$code;name=$name;label=$label;kind=$kindName;channel=$channel;event_id=(($f[9..10]|%{$_.ToString('X2')}) -join ' ');phase=[int]$f[8]}
    }
    $decoded=@{}
    if($checksumOk){
        if(($command -in @('01 04','02 04')) -and $f.Length -eq 18){$decoded.target=([int]$f[11]).ToString()+'-'+([int]($f[12]*256+$f[13])).ToString()}
        elseif($command -eq '00 03' -and $f.Length -eq 18 -and $f[16] -eq 0x7F){$decoded.target=([int]$f[11]).ToString()+'-'+([int]($f[12]*256+$f[13])).ToString();$decoded.event_id=Get-HexSlice $f 9 10;$decoded.status_prefix=Get-HexSlice $f 14 15;$decoded.withdrawn=$true}
        elseif($command -in @('01 52','02 52','00 08') -and $f.Length -ge 12){$decoded.child=([int]$f[8]).ToString()+'-'+([int]($f[9]*256+$f[10])).ToString()}
        elseif($command -in @('01 51','02 51') -and $f.Length -eq 23){$decoded.version_bytes=($f[11..12]|%{$_.ToString('X2')}) -join ' '}
        elseif($command -eq '00 02' -and $f.Length -ge 13){$decoded.clock_hm=('{0:D2}:{1:D2}' -f $f[8],$f[9]);$decoded.clock_text=Decode-Text $f 10 ($f.Length-11) 20127}
        elseif($command -eq '00 07' -and $f.Length -ge 14){$decoded.device_name=Decode-Text $f 11 ($f.Length-12) 437}
        elseif($command -eq '00 0A' -and $f.Length -ge 12){$decoded.system_text=Decode-Text $f 9 ($f.Length-10) 437}
    }
    if($signal){$status=$signal.label}
    $hex=($f|%{$_.ToString('X2')}) -join ' '
    $message=if($central){$central.target+' · '+$central.name+': '+$(if($central.label){$central.label}else{$central.code})}
        elseif($decoded.withdrawn){$decoded.target+': Meldung '+$decoded.event_id+' / '+$decoded.status_prefix+' zurückgenommen'}
        elseif($command -eq '01 03'){if($status){$status}else{'Unbekannter Status '+$statusKey}}
        elseif($signal){$signal.label+' ('+$command+': '+(Get-HexSlice $f 8 ($f.Length-2))+')'}
        elseif($sync -eq 'AA 55' -and $command -eq '00 80' -and $f.Length -ge 10){'Quittung zu Typ '+('{0:X2}' -f $f[8])}
        elseif($sync -eq 'AA 55'){'Systemtelegramm Typ '+$command+'; Daten '+(Get-HexSlice $f 8 ($f.Length-2))}
        elseif($sync -eq '55 AA' -and $command -in @('01 80','02 80')){'Antwort Typ '+$command}
        else{'Typ '+$command+'; Daten '+(Get-HexSlice $f 8 ($f.Length-2))}
    if($decoded.device_name){$message='Gerätebezeichner '+$decoded.device_name+' · Typ '+$command}
    elseif($decoded.child){$message='Typ '+$command+' · ZiBus_TLN '+$decoded.child}
    elseif($decoded.clock_text){$message='Uhrzeit '+$decoded.clock_text}
    elseif($decoded.system_text){$message='Systemtext '+$decoded.system_text+' · Typ '+$command}
    if(-not $checksumOk){$script:bus.frames++;$script:bus.checksum_errors++;$script:bus.errors++;Add-Event 'error' ($id+': Prüfsumme ungültig ('+('{0:X2}' -f $f[-1])+' statt '+('{0:X2}' -f $expected)+')') $id $hex;return}
    $script:bus.frames++;$script:bus.valid_frames++
    $d=Add-Device $id;$d.count++;$d.last_seen=Get-Now;$d.name=if($decoded.device_name){$decoded.device_name}else{$d.name}
    $d.types[$command]=1+[int]$(if($d.types.ContainsKey($command)){$d.types[$command]}else{0})
    $item=@{time=(Get-Now);message=$message;hex=$hex;command=$command;sync=$sync;checksum_ok=$true;decoded=$decoded}
    $d.history.Insert(0,$item);while($d.history.Count -gt 2){$d.history.RemoveAt($d.history.Count-1)}
    if($signal -and $decoded.target){
        $cid=Canonical-Id $decoded.target
        if(-not $script:children.ContainsKey($cid)){$script:children[$cid]=@{count=0;signals=@{}}}
        $c=$script:children[$cid];$c.parent=$id;$c.last_seen=Get-Now;$c.command=$command;$c.payload_hex=(Get-HexSlice $f 8 ($f.Length-2));$c.count++
        $c.signals[$signal.code]=@{code=$signal.code;name=$signal.name;active=$signal.active;mode=$signal.mode;label=$signal.label;time=(Get-Now);source=$id}
    }elseif($signal){$d.signals[$signal.code]=@{code=$signal.code;name=$signal.name;active=$signal.active;mode=$signal.mode;label=$signal.label;time=(Get-Now)}}
    if($central){
        if(-not $script:targets.ContainsKey($central.target)){$script:targets[$central.target]=@{count=0;last_seen=(Get-Now);name='';statuses=@{};channels=@{}}}
        $t=$script:targets[$central.target];$t.count++;$t.last_seen=Get-Now
        if($central.name -and -not $central.channel){$t.name=$central.name}
        $record=@{target=$central.target;code=$central.code;name=$central.name;label=$central.label;kind=$central.kind;channel=$central.channel;event_id=$central.event_id;phase=$central.phase;time=(Get-Now);source=$id;active=$true}
        $t.statuses[$central.kind]=$record
        if($central.channel){$t.channels[$central.channel]=$record}
        if($central.kind -eq 'fault' -and $id -eq '0-0'){$script:bus.station_fault_reports++;Add-Telemetry $central.target 'station_fault' 1}
        Add-Event 'change' ($central.target+' · '+$central.name+': '+$(if($central.label){$central.label}else{$central.code})+' (gemeldet von '+$id+')') $central.target $hex
    }
    if($decoded.withdrawn -and $id -eq '0-0'){
        $cid=Canonical-Id $decoded.target
        if($script:targets.ContainsKey($cid)){
            $t=$script:targets[$cid]
            foreach($kind in @($t.statuses.Keys)){
                $record=$t.statuses[$kind]
                if($record.event_id -eq $decoded.event_id -and $record.code.StartsWith($decoded.status_prefix) -and (-not $record.ContainsKey('active') -or $record.active -ne $false)){
                    $label=$(if($record.label){$record.label}elseif($record.name){$record.name}else{$kind})+' beendet'
                    $record.active=$false;$record.time=Get-Now;$record.label=$label;$record.source=$id;$t.last_seen=Get-Now
                    Add-Event 'change' ($cid+' · '+$label) $cid $hex
                }
            }
        }
    }
    if($command -in @('01 52','02 52','00 08') -and $decoded.child){
        $cid=Canonical-Id $decoded.child
        if(-not $script:children.ContainsKey($cid)){$script:children[$cid]=@{count=0;signals=@{}}}
        $c=$script:children[$cid];$c.parent=$id;$c.last_seen=Get-Now;$c.command=$command;$c.payload_hex=(Get-HexSlice $f 8 ($f.Length-2));$c.count++
    }
    Add-Telemetry $id 'frame' 1
    $signature=$hex
    if($d.seen_frames.ContainsKey($signature)){$d.repetitions++;$script:bus.repetitions++;Add-Telemetry $id 'repeat' 1}
    $d.seen_frames[$signature]=1
    if($status -and -not $central -and $id -ne '0-0' -and $status -ne $d.last_status){$d.last_status=$status;Add-Event 'change' ($id+': '+$status) $id $hex}
    Write-CaptureLine @{type='frame';time=(Get-Now);device=$id;sync=$sync;command=$command;status=$status;checksum_ok=$true;message=$message;decoded=$decoded;hex=$hex}
    if($command -notin @('01 03','01 04','02 04','01 51','01 52','00 01','00 02','00 07','00 08','00 0A','00 50','00 80','01 80','02 80','02 51','02 52','00 03','01 06','02 03','02 06','06 03') -or ($command -eq '01 03' -and -not $status -and (-not $central -or $central.kind -eq 'other'))){
        $d.errors.unknown++;$script:bus.unknown++;Add-Event 'unknown' ($id+': unbekanntes Telegramm '+$command+' / '+$(if($statusKey){$statusKey}else{'ohne Status'})) $id $hex
    }
}
function Process-Bytes([byte[]]$chunk){
    if($script:captureBin){$script:captureBin.Write($chunk,0,$chunk.Length);$script:captureBin.Flush()}
    $now=Get-Now
    if($null -ne $script:lastBusRx){
        $gap=$now-[double]$script:lastBusRx
        $script:bus.longest_gap_seconds=[Math]::Max([double]$script:bus.longest_gap_seconds,$gap)
        if($gap -ge [int]$script:cfg.quiet_warn_seconds){$script:bus.quiet_gaps++;Add-Telemetry 'Bus' 'gap' $gap;Add-Event 'gap' ('Busruhe '+[Math]::Round($gap,1)+' s') '' '' @{gap_seconds=$gap;level=$(if($gap -ge [int]$script:cfg.quiet_critical_seconds){'critical'}else{'warning'})}}
    }
    $script:lastBusRx=$now;$script:bus.bytes+=$chunk.Length
    foreach($b in $chunk){$script:buffer.Add([byte]$b)}
    while($script:buffer.Count -gt 0){
        $arr=$script:buffer.ToArray();$pos=Find-Sync $arr
        if($pos -lt 0){
            $keep=0;if($arr.Length -gt 0 -and $arr[-1] -in @(0x55,0xAA)){$keep=1}
            $junkCount=$arr.Length-$keep
            if($junkCount -gt 0){$junk=$script:buffer.GetRange(0,$junkCount).ToArray();$script:buffer.RemoveRange(0,$junkCount);$script:bus.unframed+=$junkCount;$script:bus.errors++;Add-Event 'error' ($junkCount+' ungerahmte Byte(s)') '' (($junk|%{$_.ToString('X2')}) -join ' ')}
            break
        }
        if($pos -gt 0){$junk=$script:buffer.GetRange(0,$pos).ToArray();$script:buffer.RemoveRange(0,$pos);$script:bus.unframed+=$pos;$script:bus.errors++;Add-Event 'error' ($pos+' Byte(s) vor Sync') '' (($junk|%{$_.ToString('X2')}) -join ' ');continue}
        if($script:buffer.Count -lt 3){break}
        $length=[int]$script:buffer[2]
        if($length -lt 8 -or $length -gt 96){$bad=$script:buffer.GetRange(0,3).ToArray();$script:buffer.RemoveAt(0);$script:bus.malformed++;$script:bus.errors++;Add-Event 'error' ('Unplausibles Längenbyte '+$length) '' (($bad|%{$_.ToString('X2')}) -join ' ');continue}
        if($script:buffer.Count -lt $length){break}
        $frame=$script:buffer.GetRange(0,$length).ToArray();$script:buffer.RemoveRange(0,$length);Decode-Frame $frame
    }
}
function Get-Snapshot {
    $now=Get-Now;$deviceList=@()
    foreach($d in $script:devices.Values){
        $age=[Math]::Max(0,$now-[double]$d.last_seen)
        $copy=[ordered]@{};foreach($key in $d.Keys){if($key -notin @('seen_frames','last_signature')){$copy[$key]=$d[$key]}}
        $copy.age=$age;$copy.state=if($age -ge [int]$script:cfg.offline_seconds){'offline'}elseif($age -ge [int]$script:cfg.stale_seconds){'stale'}else{'online'}
        $deviceList+=,$copy
    }
    $silence=$null;$level='active'
    if($null -ne $script:lastBusRx){$silence=[Math]::Max(0,$now-[double]$script:lastBusRx);if($silence -ge [int]$script:cfg.quiet_critical_seconds){$level='critical'}elseif($silence -ge [int]$script:cfg.quiet_warn_seconds){$level='warning'}}
    return [ordered]@{
        now=$now;reset_at=$script:resetAt;devices=@($deviceList);central_targets=$script:targets;embedded_children=$script:children
        playback=$script:playback;bus=$script:bus;current_silence_seconds=$silence;silence_level=$level;repeat_ratio=0
        events=@($script:events.ToArray());telemetry=@($script:telemetry.ToArray());config=$script:cfg;monitor_running=$script:running
        port_error=$script:portError;capture_file=$script:captureFile
    }
}
function Read-HttpLine($stream){
    $bytes=[System.Collections.Generic.List[byte]]::new()
    while($true){$v=$stream.ReadByte();if($v -lt 0 -or $v -eq 10){break};if($v -ne 13){$bytes.Add([byte]$v)}}
    return [Text.Encoding]::ASCII.GetString($bytes.ToArray())
}
function Reply($stream,[string]$status,[string]$content,[string]$type='application/json; charset=utf-8'){
    $body=[Text.Encoding]::UTF8.GetBytes($content);$crlf=[string]([char]13)+[char]10
    $head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+$crlf+'Content-Type: '+$type+$crlf+'Content-Length: '+$body.Length+$crlf+'Connection: close'+$crlf+'Cache-Control: no-store'+$crlf+$crlf)
    $stream.Write($head,0,$head.Length);$stream.Write($body,0,$body.Length)
}
function Reply-Binary($stream,[string]$status,[byte[]]$body,[string]$type){
    $crlf=[string]([char]13)+[char]10
    $head=[Text.Encoding]::ASCII.GetBytes('HTTP/1.1 '+$status+$crlf+'Content-Type: '+$type+$crlf+'Content-Length: '+$body.Length+$crlf+'Connection: close'+$crlf+'Cache-Control: public, max-age=86400'+$crlf+$crlf)
    $stream.Write($head,0,$head.Length);$stream.Write($body,0,$body.Length)
}
function Persist-Config {
    $json=ConvertTo-Json -InputObject $script:cfg -Depth 20
    [IO.File]::WriteAllText($script:configPath,$json,[Text.UTF8Encoding]::new($false))
}
function Get-Recordings {
    $items=@()
    foreach($file in Get-ChildItem -LiteralPath $script:dataDir -Filter 'p7_*.jsonl' -File -ErrorAction SilentlyContinue){
        $items+=,@{id=('local:'+$file.Name);name=$file.Name;source='local';bytes=$file.Length}
    }
    return @($items)
}
function Load-Playback([string]$fileId,[double]$speed){
    if($script:running){throw 'Live-Mitschnitt zuerst stoppen'}
    if($speed -lt 0.25 -or $speed -gt 100){throw 'Geschwindigkeit muss zwischen 0,25x und 100x liegen'}
    $name=$fileId -replace '^local:',''
    if($name -notmatch '^p7_[A-Za-z0-9_-]+\.jsonl$'){throw 'Ungültige Mitschnittdatei'}
    $path=Join-Path $script:dataDir $name;if(-not (Test-Path -LiteralPath $path)){throw 'Mitschnitt nicht gefunden'}
    $rows=[System.Collections.Generic.List[object]]::new()
    foreach($line in Get-Content -LiteralPath $path -Encoding UTF8){
        try{$x=$line|ConvertFrom-Json;if($x.type -eq 'frame' -and $x.hex){$bytes=@($x.hex -split '\s+'|%{[Convert]::ToByte($_,16)});$rows.Add(@{type='frame';time=[double]$x.time;bytes=[byte[]]$bytes})}elseif($x.type -eq 'marker'){$rows.Add(@{type='marker';time=[double]$x.time;message=[string]$x.message})}}catch{}
    }
    if($rows.Count -eq 0){throw 'Keine abspielbaren Telegramme in der Aufnahme'}
    $script:playbackRows=$rows.ToArray();$script:playback.source_time=$null;Reset-Metrics
    $markers=@();for($i=0;$i -lt $script:playbackRows.Count;$i++){if($script:playbackRows[$i].type -eq 'marker'){$markers+=,@{index=$i;time=$script:playbackRows[$i].time;message=$script:playbackRows[$i].message}}}
    $script:playback=[ordered]@{state='playing';file=$fileId;index=0;total=$script:playbackRows.Count;speed=$speed;source_time=$script:playbackRows[0].time;start_time=$script:playbackRows[0].time;end_time=$script:playbackRows[-1].time;markers=@($markers|Select-Object -First 500)}
    $script:playbackNextAt=[DateTime]::UtcNow
}
function Tick-Playback {
    if($script:playback.state -ne 'playing'){return}
    $i=[int]$script:playback.index
    if($i -ge $script:playbackRows.Count){$script:playback.state='finished';return}
    if([DateTime]::UtcNow -lt $script:playbackNextAt){return}
    $row=$script:playbackRows[$i];$script:playback.source_time=[double]$row.time
    if($row.type -eq 'frame'){Decode-Frame $row.bytes}else{Add-Event 'marker' ('Aufnahme: '+$row.message)}
    $script:playback.index=$i+1
    if($i+1 -lt $script:playbackRows.Count){
        $delta=[Math]::Max(0,[double]$script:playbackRows[$i+1].time-[double]$row.time)/[Math]::Max(.25,[double]$script:playback.speed)
        $script:playbackNextAt=[DateTime]::UtcNow.AddSeconds($delta)
    }
}
function Handle-Api($method,[string]$path,[string]$body){
    if($method -eq 'GET' -and $path -eq '/api/state'){return @{status='ok';content=(ConvertTo-Json -InputObject (Get-Snapshot) -Depth 25 -Compress);type='application/json; charset=utf-8'}}
    if($method -eq 'GET' -and $path -eq '/api/recordings'){return @{status='ok';content=(ConvertTo-Json -InputObject @(Get-Recordings) -Depth 8 -Compress);type='application/json; charset=utf-8'}}
    if($method -eq 'GET' -and $path -eq '/api/export'){$snap=Get-Snapshot;return @{status='ok';content=(ConvertTo-Json -InputObject $snap -Depth 25);type='application/json; charset=utf-8'}}
    if($method -ne 'POST'){return @{status='404 Not Found';content='Not found';type='text/plain; charset=utf-8'}}
    $data=if($body){$body|ConvertFrom-Json}else{@{}}
    switch($path){
        '/api/control'{
            if($data.action -eq 'start'){Start-Monitor}else{Stop-Monitor}
            return @{status='ok';content='ok';type='text/plain; charset=utf-8'}
        }
        '/api/reset'{Reset-Metrics;return @{status='ok';content='ok';type='text/plain; charset=utf-8'}}
        '/api/config'{
            foreach($key in @('port','baud','stale_seconds','offline_seconds','quiet_warn_seconds','quiet_critical_seconds','reply_timeout_seconds')){if($data.PSObject.Properties[$key]){$script:cfg[$key]=$data.$key}}
            if($data.PSObject.Properties['group_types']){$script:cfg.group_types=$data.group_types}
            Persist-Config
            return @{status='ok';content='ok';type='text/plain; charset=utf-8'}
        }
        '/api/marker'{$message=[string]$data.message;if(-not $message){$message='Zeitmarker'};Add-Event 'marker' $message ([string]$data.device) '' @{category=[string]$data.category;section=[string]$data.section};return @{status='ok';content='ok';type='text/plain; charset=utf-8'}}
        '/api/playback'{
            switch([string]$data.action){
                'start'{Load-Playback ([string]$data.file) ([double]$data.speed)}
                'pause'{$script:playback.state='paused'}
                'resume'{$script:playback.state='playing';$script:playbackNextAt=[DateTime]::UtcNow}
                'stop'{$script:playback.state='stopped';$script:playbackRows=@();$script:playback.source_time=$null}
                'speed'{$script:playback.speed=[double]$data.speed}
                'seek'{$target=[Math]::Max(0,[Math]::Min([int]$data.index,$script:playbackRows.Count));Reset-Metrics;$script:playback.source_time=$null;$script:playback.index=0;for($j=0;$j -lt $target;$j++){$row=$script:playbackRows[$j];$script:playback.source_time=[double]$row.time;if($row.type -eq 'frame'){Decode-Frame $row.bytes}else{Add-Event 'marker' ('Aufnahme: '+$row.message)};$script:playback.index++};$script:playback.state='paused';if($target -lt $script:playbackRows.Count){$script:playback.source_time=[double]$script:playbackRows[$target].time}}
                default{throw 'Unbekannte Wiedergabeaktion'}
            }
            return @{status='ok';content='ok';type='text/plain; charset=utf-8'}
        }
        default{return @{status='404 Not Found';content='Not found';type='text/plain; charset=utf-8'}}
    }
}
$server=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$HttpPort);$server.Start()
$url='http://127.0.0.1:'+$HttpPort+'/';Write-Host ('P7-Monitor läuft lokal: '+$url) -ForegroundColor Cyan
$lastRetry=[DateTime]::UtcNow
try{
    while($true){
        if($script:running -and $script:serial){
            try{
                $available=$script:serial.BytesToRead
                if($available -gt 0){$chunk=New-Object byte[] ([Math]::Min($available,4096));$n=$script:serial.Read($chunk,0,$chunk.Length);if($n -gt 0){if($n -lt $chunk.Length){$chunk=$chunk[0..($n-1)]};Process-Bytes $chunk}}
            }catch [TimeoutException]{}catch{$script:portError=$_.Exception.Message;$script:bus.disconnects++;Add-Event 'error' ('Serieller Port: '+$script:portError);Stop-Monitor}
        }
        Tick-Playback
        if(-not $server.Pending()){Start-Sleep -Milliseconds 10;continue}
        $client=$server.AcceptTcpClient();$stream=$client.GetStream();$stream.ReadTimeout=5000
        try{
            $request=Read-HttpLine $stream;$parts=$request.Split(' ');$method=$parts[0];$path=$parts[1].Split('?')[0]
            $headers=@{};while($true){$line=Read-HttpLine $stream;if($null -eq $line -or $line -eq ''){break};$ix=$line.IndexOf(':');if($ix -gt 0){$headers[$line.Substring(0,$ix).ToLowerInvariant()]=$line.Substring($ix+1).Trim()}}
            $length=0;if($headers.ContainsKey('content-length')){$length=[int]$headers['content-length']}
            $body='';if($length -gt 0){$bytes=New-Object byte[] $length;$offset=0;while($offset -lt $length){$n=$stream.Read($bytes,$offset,$length-$offset);if($n -le 0){break};$offset+=$n};$body=[Text.Encoding]::UTF8.GetString($bytes,0,$offset)}
            if($path.StartsWith('/api/')){$response=Handle-Api $method $path $body;Reply $stream $response.status $response.content $response.type}
            elseif($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')){Reply $stream '200 OK' ([IO.File]::ReadAllText((Join-Path $script:root 'index.html'))) 'text/html; charset=utf-8'}
            elseif($method -eq 'GET' -and $path -eq '/icon.svg'){Reply $stream '200 OK' ([IO.File]::ReadAllText((Join-Path $script:root 'icon.svg'))) 'image/svg+xml'}
            elseif($method -eq 'GET' -and $path -eq '/icon.ico'){Reply-Binary $stream '200 OK' ([IO.File]::ReadAllBytes((Join-Path $script:root 'icon.ico'))) 'image/x-icon'}
            else{Reply $stream '404 Not Found' 'Not found' 'text/plain; charset=utf-8'}
        }catch{try{Reply $stream '400 Bad Request' $_.Exception.Message 'text/plain; charset=utf-8'}catch{}}
        finally{$stream.Dispose();$client.Close()}
    }
}catch{
    Write-Host $_.Exception.Message -ForegroundColor Red
}finally{
    Stop-Monitor
    $server.Stop()
}
