[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LdapsName,

    [Parameter(Mandatory = $true)]
    [pscredential]$Credential,

    [int]$Rounds = 4
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.DirectoryServices.Protocols

for ($i = 1; $i -le $Rounds; $i++) {
    Clear-DnsClientCache
    $resolved = Resolve-DnsName -Name $LdapsName -Type A | Select-Object -ExpandProperty IPAddress
    $tcpOpen = Test-NetConnection -ComputerName $LdapsName -Port 636 -InformationLevel Quiet
    $bindOk = $false
    $message = ""

    try {
        $directoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($LdapsName, 636, $false, $false)
        $connection = [System.DirectoryServices.Protocols.LdapConnection]::new($directoryIdentifier)
        $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        $connection.Credential = $Credential.GetNetworkCredential()
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.SessionOptions.SecureSocketLayer = $true
        $connection.Timeout = [TimeSpan]::FromSeconds(10)
        $connection.Bind()
        $rootDseRequest = [System.DirectoryServices.Protocols.SearchRequest]::new("", "(objectClass=*)", "Base", @("defaultNamingContext"))
        [void]$connection.SendRequest($rootDseRequest)
        $bindOk = $true
        $message = "LDAPS bind and RootDSE query succeeded"
    }
    catch {
        $message = $_.Exception.Message
    }
    finally {
        if ($connection) {
            $connection.Dispose()
        }
    }

    [pscustomobject]@{
        Attempt        = $i
        ResolvedIps    = $resolved -join ", "
        Tcp636Open     = $tcpOpen
        LdapsBindOk    = $bindOk
        Message        = $message
    }

    Start-Sleep -Seconds 1
}
