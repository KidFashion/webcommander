<#
Copyright (c) 2012-2014 VMware, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
#>

<#
	.SYNOPSIS
		Install Windows updates 

	.DESCRIPTION
		This command downloads and installs Windows updates.
		This command could execute on multiple machines.
		
	.FUNCTIONALITY
		Install, Windows
		
	.NOTES
		AUTHOR: Jerry Liu
		EMAIL: liuj@vmware.com
#>

Param (
	[parameter(
		HelpMessage="IP or FQDN of the ESX or VC server where target VM is located"
	)]
	[string]
		$serverAddress, 
	
	[parameter(
		HelpMessage="User name to connect to the server (default is root)"
	)]
	[string]
		$serverUser="root", 
	
	[parameter(
		HelpMessage="Password of the user"
	)]
	[string]
		$serverPassword=$env:defaultPassword, 
	
	[parameter(
		Mandatory=$true,
		HelpMessage="Name of target VM or IP / FQDN of target machine. Support multiple values seperated by comma. VM name and IP could be mixed."
	)]
	[string]
		$vmName, 
	
	[parameter(
		HelpMessage="User of target machine (default is administrator)"
	)]
	[string]	
		$guestUser="administrator", 
		
	[parameter(
		HelpMessage="Password of guestUser"
	)]
	[string]	
		$guestPassword=$env:defaultPassword,  
	
	[parameter(
		HelpMessage="Snapshot name. If defined, VM will be restored to the snapshot first."
	)]
	[string]
		$ssName="", 
	
	[parameter(
		HelpMessage="Windows update server from which to download updates, default is 'Internal'"
	)]
	[ValidateSet(
		"Internal",
		"External"
	)]
	[string]	
		$updateServer="External",
	
	[parameter(
		HelpMessage="Severity of the update to install, default is 'Critical'"
	)]
	[ValidateSet(
		"Critical",
		"Important",
		"Moderate",
		"Low",
		"All"
	)]
	[string]	
		$severity="Critical"
)

foreach ($paramKey in $psboundparameters.keys) {
	$oldValue = $psboundparameters.item($paramKey)
	$newValue = [System.Net.WebUtility]::urldecode("$oldValue")
	set-variable -name $paramKey -value $newValue
}

. .\objects.ps1

function windowsUpdate {
	param ($ip, $guestUser, $guestPassword, $updateServer, $severity)
	$remoteWin = newRemoteWin $ip $guestUser $guestPassword
	$remoteWin.sendFile(".\windows\updateWindowsSync2.ps1", "c:\temp\wu.ps1")
	$timeSuffix = get-date -format "-yyyy-MM-dd-hh-mm-ss"
	$cmd = "
		#remove-item c:\temp\wu.log -force -ea silentlycontinue
		#schtasks /end /tn windowsupdate
		set-executionpolicy unrestricted -force
		`$date = get-date '2014/12/31' -format (Get-ItemProperty -path 'HKCU:\Control Panel\International').sshortdate
		schtasks /create /f /tn windowsupdate /ru '$guestUser' /rp '$guestPassword' /rl HIGHEST /sc once /sd `$date /st 00:00:00 /tr 'powershell c:\temp\wu.ps1 $updateserver $severity >>c:\temp\wu$timeSuffix.log'
	"
	$remoteWin.executePsTxtRemote($cmd, "create Windows update task in VM")

	do {
		$cmd = "schtasks /run /tn windowsupdate"
		$remoteWin.executePsTxtRemote($cmd, "trigger Windows update task in VM")
		$cmd = "
			start-sleep 10
			`$s = new-object -com 'Schedule.Service'
			`$s.connect()
			do {
				`$task = `$s.getfolder('\').gettasks(0) | where {`$_.NAME -eq 'windowsupdate'} | SELECT state,lasttaskresult
				if (`$task.state -eq 3){break}
				start-sleep 30
			} while ((`$task.state -eq 4) -or (`$task.state -eq 2) -or !(test-path c:\temp\wu$timeSuffix.log))
			start-sleep 10
			get-content c:\temp\wu$timeSuffix.log -ea SilentlyContinue | select -last 1
		"
		$result = $remoteWin.executePsTxtRemote($cmd, "get update progress", 86400)
		if ($result -match "need to reboot") {
			$remoteWin.restart()
			start-sleep 100
			$remoteWin.waitforsession(30, 600)
		}
	} while ($result -notmatch "no more update")

	writeCustomizedMsg ("Success - install Windows update")
	$cmd = "
		schtasks /delete /f /tn windowsupdate | out-null
		get-content c:\temp\wu$timeSuffix.log
	"
	$result = $remoteWin.executePsTxtRemote($cmd, "get update log")
	writeStdout($result)
}

if ($ssName) {
	restoreSnapshot $ssName $vmName $serverAddress $serverUser $serverPassword
}
$ipList = getVmIpList $vmName $serverAddress $serverUser $serverPassword
$ipList | % {
	windowsUpdate $_ $guestUser $guestPassword $updateServer $severity
}