﻿<#-------------Create Deployment Start------------------#>
Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$slaveMachines = @()
		$slaveMachinesHostNames = ""
		$noMaster = $true
		$noSlave = $true
		$terasortSummary = $null
		foreach ( $vmData in $allVMData )
		{
			if ( $vmData.RoleName -imatch "master" )
			{
				$masterVMData = $vmData
				$noMaster = $false
			}
			elseif ( $vmData.RoleName -imatch "slave" )
			{
				$slaveMachines += $vmData
				$noSlave = $fase
				$slaveMachinesHostNames += "$($vmData.RoleName) "
			}
		}
		
		$slaveMachinesHostNames = $slaveMachinesHostNames.Trim()
		if ( $noMaster )
		{
			Throw "No any master VM defined. Be sure that, Master VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ( $noSlave )
		{
			Throw "No any slave VM defined. Be sure that, Slave machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		LogMsg "MASTER VM details :"
		LogMsg "  RoleName : $($masterVMData.RoleName)"
		LogMsg "  Public IP : $($masterVMData.PublicIP)"
		LogMsg "  SSH Port : $($masterVMData.SSHPort)"
		$i = 1
		foreach ( $vmData in $slaveMachines )
		{
			LogMsg "SLAVE #$i VM details :"
			LogMsg "  RoleName : $($vmData.RoleName)"
			LogMsg "  Public IP : $($vmData.PublicIP)"
			LogMsg "  SSH Port : $($vmData.SSHPort)"
			$i += 1
		}
		if ( $currentTestData.HADOOP_VERSION )
		{
			$hadoopVersion = $currentTestData.HADOOP_VERSION
			LogMsg "Hadoop version set to : $hadoopVersion from local XML file."
		}
		else
		{
			LogMsg "Downloading terasort XML : $($currentTestData.remoteXML) ..."
			$terasortXMLData =  (Invoke-WebRequest -Uri $($currentTestData.remoteXML)).Content
			$hadoopVersion = ($terasortXMLData.Split() -match "<param>HADOOP_VERSION=").Replace("<param>HADOOP_VERSION=","").Replace("</param>","") 
			LogMsg "Hadoop version set to : $hadoopVersion from remote XML file."
		}
		LogMsg "Downloading remote files ..."
		foreach ( $fileURL in  $($currentTestData.remoteFiles).Split(",") )
		{
			LogMsg "Downloading $fileURL ..."
			$start_time = Get-Date
			$fileName =  $fileURL.Split("/")[$fileURL.Split("/").Count-1]
			$out = Invoke-WebRequest -Uri $fileURL -OutFile "$LogDir\$fileName"
			LogMsg "Time taken: $((Get-Date).Subtract($start_time).Seconds) second(s)"
		}
		LogMsg "Generating constanst.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		$sshKeyPath = $currentTestData.sshKey
		$sshKey = $sshKeyPath.Split("\")[$sshKeyPath.Split("\").count -1]
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "HADOOP_MASTER_HOSTNAME=`"$($masterVMData.RoleName)`"" -Path $constantsFile
		Add-Content -Value "RESOURCE_MANAGER_HOSTNAME=`"$($masterVMData.RoleName)`"" -Path $constantsFile
		Add-Content -Value "SLAVE_HOSTNAMES=`"$slaveMachinesHostNames`"" -Path $constantsFile
		Add-Content -Value "TERAGEN_RECORDS=$($currentTestData.TERAGEN_RECORDS)" -Path $constantsFile
		Add-Content -Value "HADOOP_VERSION=`"$hadoopVersion`"" -Path $constantsFile
		Add-Content -Value "sshKey=`"/root/$sshKey`"" -Path $constantsFile
		
		#	You can add as much as teerasort test parameters here.
		
		LogMsg "constanst.sh created successfully..."
		Set-Content -Value "/root/perf_hadoopterasort.sh &> terasortConsoleLogs.txt" -Path "$LogDir\StartTerasortTest.sh"
		Set-Content -Value "echo `"Host *`" > /home/$user/.ssh/config" -Path "$LogDir\disableHostKeyVerification.sh"
		Add-Content -Value "echo StrictHostKeyChecking=no >> /home/$user/.ssh/config" -Path "$LogDir\disableHostKeyVerification.sh"
		Logmsg (Get-Content $constantsFile)
		foreach ( $vmData in $allVMData )
		{
			RemoteCopy -uploadTo $vmData.PublicIP -port $vmData.SSHPort -files ".\$constantsFile,.\$LogDir\perf_hadoopterasort.sh,.\remote-scripts\enableRoot.sh,$sshKeyPath,.\$LogDir\StartTerasortTest.sh,.\$LogDir\disableHostKeyVerification.sh" -username $user -password $password -upload
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "chmod +x /home/$user/*.sh" -runAsSudo			
			$rootPasswordSet = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username $user -password $password -command "/home/$user/enableRoot.sh -password $($password.Replace('"',''))" -runAsSudo
			LogMsg $rootPasswordSet
			if (( $rootPasswordSet -imatch "ROOT_PASSWRD_SET" ) -and ( $rootPasswordSet -imatch "SSHD_RESTART_SUCCESSFUL" ))
			{
				LogMsg "root user enabled for $($vmData.RoleName) and password set to $password"
			}
			else
			{
				Throw "Failed to enable root password / starting SSHD service. Please check logs. Aborting test."
			}
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "chmod 600 /home/$user/$sshKey && cp -ar /home/$user/* /root/"
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "mkdir -p /root/.ssh/ && cp /home/$user/.ssh/authorized_keys /root/.ssh/" 
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "/home/$user/disableHostKeyVerification.sh" 
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "cp /home/$user/.ssh/config /root/.ssh/" 
			$out = RunLinuxCmd -ip $vmData.PublicIP -port $vmData.SSHPort -username "root" -password $password -command "service sshd restart" 
		}
		#endregion

		#region EXECUTE TEST
		
		$testJob = RunLinuxCmd -ip $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -command "/root/StartTerasortTest.sh" -RunInBackground
		#endregion

		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -command "tail -n 1 /root/hadoop.log"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 10
		}
		
		$currentStatus = RunLinuxCmd -ip $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -command "tail -n 1 /root/hadoop.log"
		$finalStatus = RunLinuxCmd -ip $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		
		RemoteCopy -downloadFrom $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/terasortConsoleLogs.txt"
		RemoteCopy -downloadFrom $masterVMData.PublicIP -port $masterVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/summary.log"
		$terasortSummary = Get-Content -Path "$LogDir\summary.log" -ErrorAction SilentlyContinue
		if (!$terasortSummary)
		{
			LogMsg "summary.log file is empty."
			$terasortSummary = "<EMPTY>"
		}
		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			LogMsg "Contests of summary.log : $terasortSummary"
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			LogMsg "Contests of summary.log : $terasortSummary"
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed. Last known status : $currentStatus."
			LogMsg "$terasortSummary"
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\terasortConsoleLogs.txt"
			LogMsg "Contests of summary.log : $terasortSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "summary.log"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
		$resultSummary +=  CreateResultSummary -testResult $terasortSummary -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName# if you want to publish all result then give here all test status possibilites. if you want just failed results, then give here just "FAIL". You can use any combination of PASS FAIL ABORTED and corresponding test results will be published!
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary