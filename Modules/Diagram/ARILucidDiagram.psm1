<#
.Synopsis
Diagram Module for Lucid

.DESCRIPTION
This module builds a network topology diagram in Lucid (lucidchart/lucidspark) from a resource
cache saved by 'Invoke-ARI -SaveResourceCache'. It is a standalone export path, decoupled from
Invoke-ARI, so the Lucid document can be rebuilt/iterated on without re-collecting from Azure.

Auth model: Lucid's REST API only documents the OAuth2 authorization_code grant (not a pure
client_credentials/server-to-server flow), so a one-time interactive authorization via
Connect-ARILucidAccount is required before Export-ARILucidDiagram can be used. After that,
Export-ARILucidDiagram refreshes its access token automatically using the cached refresh token.

Scope (v1.1): Virtual Networks and Subnets render as native Lucid Azure shapes (namedContainer/
namedShape against Lucid's azure-2024 shape library - e.g. VirtualNetworkContainerAzure2024,
SubnetContainerAzure2024, VirtualMachineAzure2024), grouped by resource type per subnet. Virtual
Network peering and Local Network Gateway / VPN Gateway on-premises connections are drawn as lines.
Resource types with no azure-2024 mapping fall back to a generic labeled rectangle. ExpressRoute
and Virtual WAN topology tracing are not yet visualized.

.Link
https://developer.lucid.co/docs/overview-si
https://developer.lucid.co/reference/createorcopyorimportdocument
https://developer.lucid.co/reference/obtaining-an-access-token

.COMPONENT
This PowerShell Module is part of Azure Resource Inventory (ARI)

.NOTES
Version: 1.0.0
First Release Date: 18th July, 2026
Requires: PowerShell 6.1+ (uses System.Net.Http for multipart upload)

#>

# Maps Azure resource types to Lucid's "azure-2024" named shape library class names
# (lucid://shape-libraries/azure-2024/*). Types not listed here fall back to a generic
# labeled rectangle in New-ARILucidResourceIcon rather than being silently dropped.
$Script:ARILucidAzureIconMap = @{
    'microsoft.compute/virtualmachines'             = 'VirtualMachineAzure2024'
    'microsoft.compute/virtualmachinescalesets'     = 'VMScaleSetsAzure2024'
    'microsoft.network/networkinterfaces'           = 'NetworkInterfacesAzure2024'
    'microsoft.network/loadbalancers'                = 'LoadBalancersAzure2024'
    'microsoft.network/azurefirewalls'               = 'FirewallsAzure2024'
    'microsoft.network/applicationgateways'          = 'ApplicationGatewaysAzure2024'
    'microsoft.network/bastionhosts'                 = 'BastionsAzure2024'
    'microsoft.network/networksecuritygroups'        = 'NetworkSecurityGroupsAzure2024'
    'microsoft.network/routetables'                  = 'RouteTablesAzure2024'
    'microsoft.network/publicipaddresses'            = 'PublicIPAddressesAzure2024'
    'microsoft.network/privateendpoints'             = 'PrivateLinkAzure2024'
    'microsoft.network/natgateways'                  = 'NATAzure2024'
    'microsoft.network/virtualnetworkgateways'       = 'VirtualNetworkGatewaysAzure2024'
    'microsoft.containerservice/managedclusters'     = 'KubernetesServicesAzure2024'
}

function Get-ARILucidShapeClassName {
    Param($ResourceType)

    $Key = ([string]$ResourceType).ToLowerInvariant()
    if ($Script:ARILucidAzureIconMap.ContainsKey($Key)) {
        return $Script:ARILucidAzureIconMap[$Key]
    }

    return $null
}

function Get-ARILucidResourceGroupName {
    Param($ResourceId)

    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    return $null
}

function Get-ARILucidNetworkGraph {
    Param($CacheFolder)

    $ResourcesPath = Join-Path $CacheFolder 'resources.json'
    $SubscriptionsPath = Join-Path $CacheFolder 'subscriptions.json'

    if (!(Test-Path -Path $ResourcesPath)) {
        throw ('Resource cache not found at ' + $ResourcesPath + '. Run Invoke-ARI -SaveResourceCache first.')
    }

    $Resources = Get-Content -Path $ResourcesPath -Raw | ConvertFrom-Json
    $Subscriptions = if (Test-Path -Path $SubscriptionsPath) { Get-Content -Path $SubscriptionsPath -Raw | ConvertFrom-Json } else { @() }

    return @{
        Resources     = $Resources
        Subscriptions = $Subscriptions
        AZVNETs       = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/virtualnetworks' })
        AZLGWs        = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/localnetworkgateways' })
        AZVGWs        = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/virtualnetworkgateways' })
        AZCONs        = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/connections' })
        AZEXPROUTEs   = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/expressroutecircuits' })
        AZVWAN        = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/virtualwans' })
        AZVHUB        = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/virtualhubs' })
        PIPs          = @($Resources | Where-Object { $_.Type -eq 'microsoft.network/publicipaddresses' })
    }
}

function Get-ARILucidSubnetResources {
    <#
    Matches resources to a subnet primarily via a NIC's ipConfiguration -> subnet reference.
    A bare NIC isn't very informative on a diagram, so NICs that are attached to a VM
    (properties.virtualMachine.id) are resolved back to that VM before being returned - matching
    what a reader actually expects to see living "in" the subnet. Duplicates from multi-NIC VMs
    are collapsed by resource id.
    #>
    Param($Subnet, $Resources)

    $Matched = @($Resources | Where-Object {
            ($_.properties.ipConfigurations.properties.subnet.id -eq $Subnet.id) -or
            ($_.properties.subnet.id -eq $Subnet.id) -or
            ($_.properties.ipConfiguration.subnet.id -eq $Subnet.id)
        })

    $Resolved = @($Matched | ForEach-Object {
            $CurrentResource = $_
            if ($CurrentResource.Type -eq 'microsoft.network/networkinterfaces' -and $CurrentResource.properties.virtualMachine.id) {
                $OwningVMId = $CurrentResource.properties.virtualMachine.id
                $OwningVM = $Resources | Where-Object { $_.Type -eq 'microsoft.compute/virtualmachines' -and $_.id -eq $OwningVMId } | Select-Object -First 1
                if ($OwningVM) { $OwningVM } else { $CurrentResource }
            }
            else {
                $CurrentResource
            }
        })

    return @($Resolved | Sort-Object -Property id -Unique)
}

function New-ARILucidShape {
    Param($Id, $Type = 'rectangle', $X, $Y, $W, $H, $FillColor = '#FFFFFF', $StrokeColor = '#666666', $Text = '', $ZIndex = 0)

    return [ordered]@{
        id          = $Id
        type        = $Type
        boundingBox = [ordered]@{ x = $X; y = $Y; w = $W; h = $H }
        style       = [ordered]@{
            fill   = [ordered]@{ type = 'color'; color = $FillColor }
            stroke = [ordered]@{ color = $StrokeColor; width = 1; style = 'solid' }
        }
        text        = $Text
        zIndex      = $ZIndex
    }
}

function New-ARILucidNamedShape {
    Param($Id, $ClassName, $X, $Y, $W, $H, $Text = '', $ZIndex = 0)

    return [ordered]@{
        id          = $Id
        type        = 'namedShape'
        className   = $ClassName
        boundingBox = [ordered]@{ x = $X; y = $Y; w = $W; h = $H }
        text        = $Text
        zIndex      = $ZIndex
    }
}

function New-ARILucidNamedContainer {
    Param($Id, $ClassName, $X, $Y, $W, $H, $Text = '', $AssistedLayout = $false, $ZIndex = 0)

    return [ordered]@{
        id             = $Id
        type           = 'namedContainer'
        className      = $ClassName
        boundingBox    = [ordered]@{ x = $X; y = $Y; w = $W; h = $H }
        text           = $Text
        assistedLayout = [bool]$AssistedLayout
        zIndex         = $ZIndex
    }
}

function New-ARILucidResourceIcon {
    <#
    Builds either a native Lucid Azure shape (when the resource type is in
    $Script:ARILucidAzureIconMap) or a generic labeled-rectangle fallback.
    #>
    Param($Id, $ResourceType, $X, $Y, $Text, $ZIndex = 2)

    $ClassName = Get-ARILucidShapeClassName -ResourceType $ResourceType

    if ($ClassName) {
        return New-ARILucidNamedShape -Id $Id -ClassName $ClassName -X $X -Y $Y -W 90 -H 90 -Text $Text -ZIndex $ZIndex
    }

    return New-ARILucidShape -Id $Id -X $X -Y $Y -W 160 -H 60 -FillColor '#FFFFFF' -StrokeColor '#999999' -Text $Text -ZIndex $ZIndex
}

function New-ARILucidLine {
    Param($Id, $SourceShapeId, $TargetShapeId, $Text, $EndpointStyle = 'none')

    $Line = [ordered]@{
        id        = $Id
        lineType  = 'elbow'
        endpoint1 = [ordered]@{ type = 'shapeEndpoint'; style = 'none'; shapeId = $SourceShapeId }
        endpoint2 = [ordered]@{ type = 'shapeEndpoint'; style = $EndpointStyle; shapeId = $TargetShapeId }
        stroke    = [ordered]@{ color = '#666666'; width = 1; style = 'solid' }
    }

    if ($Text) {
        $Line.text = @([ordered]@{ text = $Text; position = 0.5 })
    }

    return $Line
}

function Build-ARILucidDocument {
    Param($Graph, $PageTitle = 'Network Topology')

    $Shapes = [System.Collections.Generic.List[object]]::new()
    $Lines = [System.Collections.Generic.List[object]]::new()
    $Groups = [System.Collections.Generic.List[object]]::new()

    $Script:ARILucidIdSeq = 0
    function NextARILucidId {
        $Script:ARILucidIdSeq++
        return ('id-' + $Script:ARILucidIdSeq)
    }

    $VNetContainerIds = @{}
    $VGWIconIds = @{}
    $VNetY = 40

    foreach ($VNet in $Graph.AZVNETs) {
        $Subnets = @($VNet.properties.subnets)
        $SubnetCount = [Math]::Max(1, $Subnets.Count)

        $VNetWidth = ($SubnetCount * 240) + 40
        $VNetHeight = 260

        $IsHub = 'GatewaySubnet' -in $Subnets.name
        $AddressSpace = ($VNet.properties.addressSpace.addressPrefixes -join ', ')
        $VNetText = $VNet.name + "`n" + $AddressSpace + $(if ($IsHub) { "`n(Hub)" })

        # VNet containers hold other containers (subnets), so per Lucid's assisted-layout
        # guidance they should NOT have assistedLayout enabled - only the subnet containers
        # they hold do, since those hold plain resource shapes.
        $VNetShapeId = NextARILucidId
        $Shapes.Add((New-ARILucidNamedContainer -Id $VNetShapeId -ClassName 'VirtualNetworkContainerAzure2024' -X 320 -Y $VNetY -W $VNetWidth -H $VNetHeight -Text $VNetText -AssistedLayout $false -ZIndex 0))

        $VNetContainerIds[$VNet.id] = $VNetShapeId

        $GroupItems = [System.Collections.Generic.List[object]]::new()
        $GroupItems.Add($VNetShapeId)

        $SubnetX = 340
        foreach ($Subnet in $Subnets) {
            $SubnetShapeId = NextARILucidId
            $SubnetText = $Subnet.name + "`n" + $Subnet.properties.addressPrefix

            $Shapes.Add((New-ARILucidNamedContainer -Id $SubnetShapeId -ClassName 'SubnetContainerAzure2024' -X $SubnetX -Y ($VNetY + 60) -W 220 -H 180 -Text $SubnetText -AssistedLayout $true -ZIndex 1))
            $GroupItems.Add($SubnetShapeId)

            $SubnetResources = Get-ARILucidSubnetResources -Subnet $Subnet -Resources $Graph.Resources
            $IconX = $SubnetX + 20
            $IconY = $VNetY + 100

            foreach ($TypeGroup in @($SubnetResources | Group-Object -Property Type)) {
                $IconId = NextARILucidId
                $IconText = if ($TypeGroup.Count -gt 1) {
                    ([string]$TypeGroup.Count + 'x ' + ($TypeGroup.Name -split '/')[-1])
                }
                else {
                    $TypeGroup.Group[0].Name
                }

                $Shapes.Add((New-ARILucidResourceIcon -Id $IconId -ResourceType $TypeGroup.Name -X $IconX -Y $IconY -Text $IconText))
                $GroupItems.Add($IconId)

                # Track VPN gateway icons by resource id so the on-prem section below can draw
                # its connection line straight to the gateway icon instead of the whole VNet box.
                if ($TypeGroup.Name -eq 'microsoft.network/virtualnetworkgateways') {
                    foreach ($VGWResource in $TypeGroup.Group) {
                        $VGWIconIds[$VGWResource.id] = $IconId
                    }
                }

                $IconY += 110
            }

            $SubnetX += 240
        }

        $Groups.Add([ordered]@{ id = (NextARILucidId); items = @($GroupItems) })

        $VNetY += ($VNetHeight + 80)
    }

    # VNet-to-VNet peering. Peerings are declared on both sides of the relationship, so track
    # which unordered VNet-id pairs have already been drawn to avoid a duplicate line per pair.
    $DrawnPeerings = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($VNet in $Graph.AZVNETs) {
        foreach ($Peering in @($VNet.properties.virtualNetworkPeerings)) {
            if (!$Peering) { continue }
            $RemoteId = $Peering.properties.remoteVirtualNetwork.id
            if (!$RemoteId -or !$VNetContainerIds.ContainsKey($VNet.id) -or !$VNetContainerIds.ContainsKey($RemoteId)) { continue }

            $PairKey = (@($VNet.id, $RemoteId) | Sort-Object) -join '|'
            if ($DrawnPeerings.Contains($PairKey)) { continue }
            $DrawnPeerings.Add($PairKey) | Out-Null

            $Lines.Add((New-ARILucidLine -Id (NextARILucidId) -SourceShapeId $VNetContainerIds[$VNet.id] -TargetShapeId $VNetContainerIds[$RemoteId] -Text 'Peered'))
        }
    }

    # On-premises connectivity: Local Network Gateways -> Connections -> Virtual Network Gateways.
    # The VGW's own icon (placed above, inside its GatewaySubnet, since VGWs match the subnet
    # resource matcher via ipConfigurations same as a NIC) is used as the line target when found;
    # falling back to the owning VNet container covers the case where the cache has a VGW without
    # a resolvable subnet match. VNet-to-VGW fallback matching is a resource-group-name heuristic
    # (VGW lives in the hub VNet's RG and the hub VNet has a GatewaySubnet), not exact
    # ipConfiguration-path matching like the draw.io renderer does. ExpressRoute/vWAN topology is
    # intentionally not traced yet.
    $OnPremX = 20
    $OnPremY = 40

    foreach ($LGW in $Graph.AZLGWs) {
        $LGWShapeId = NextARILucidId
        $Shapes.Add((New-ARILucidNamedShape -Id $LGWShapeId -ClassName 'LocalNetworkGatewaysAzure2024' -X $OnPremX -Y $OnPremY -W 120 -H 120 -Text ($LGW.name + "`n" + [string]$LGW.properties.gatewayIpAddress) -ZIndex 0))

        $Connections = @($Graph.AZCONs | Where-Object { $_.properties.localNetworkGateway2.id -eq $LGW.id })
        foreach ($Con in $Connections) {
            $VGW = $Graph.AZVGWs | Where-Object { $_.id -eq $Con.properties.virtualNetworkGateway1.id } | Select-Object -First 1
            if (!$VGW) { continue }

            $TargetShapeId = $VGWIconIds[$VGW.id]

            if (!$TargetShapeId) {
                $VGWResourceGroup = Get-ARILucidResourceGroupName -ResourceId $VGW.id
                $OwningVNet = $Graph.AZVNETs | Where-Object {
                    (Get-ARILucidResourceGroupName -ResourceId $_.id) -eq $VGWResourceGroup -and 'GatewaySubnet' -in @($_.properties.subnets.name)
                } | Select-Object -First 1

                if ($OwningVNet) {
                    $TargetShapeId = $VNetContainerIds[$OwningVNet.id]
                }
            }

            if ($TargetShapeId) {
                $Lines.Add((New-ARILucidLine -Id (NextARILucidId) -SourceShapeId $LGWShapeId -TargetShapeId $TargetShapeId -Text $Con.name))
            }
        }

        $OnPremY += 140
    }

    return [ordered]@{
        version = 1
        pages   = @(
            [ordered]@{
                id     = 'page-1'
                title  = $PageTitle
                shapes = @($Shapes)
                lines  = @($Lines)
                groups = @($Groups)
            }
        )
    }
}

function New-ARILucidImportPackage {
    Param($Document)

    $WorkingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('ARILucid_' + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $WorkingDirectory -Force | Out-Null

    try {
        $DocumentJsonPath = Join-Path $WorkingDirectory 'document.json'
        $Document | ConvertTo-Json -Depth 20 -Compress | Out-File -FilePath $DocumentJsonPath -Encoding utf8 -NoNewline

        $PackagePath = Join-Path ([System.IO.Path]::GetTempPath()) (([guid]::NewGuid().ToString()) + '.lucid')
        if (Test-Path -Path $PackagePath) {
            Remove-Item -Path $PackagePath -Force
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory($WorkingDirectory, $PackagePath)

        return $PackagePath
    }
    finally {
        Remove-Item -Path $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-ARILucidImport {
    Param($PackagePath, $AccessToken, $Title, $Product = 'lucidchart')

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

    $HttpClient = [System.Net.Http.HttpClient]::new()
    $Form = $null

    try {
        $HttpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $AccessToken)
        $HttpClient.DefaultRequestHeaders.Add('Lucid-Api-Version', '1')

        $FileBytes = [System.IO.File]::ReadAllBytes($PackagePath)
        $FileContent = [System.Net.Http.ByteArrayContent]::new($FileBytes)
        $FileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('x-application/vnd.lucid.standardImport')

        $Form = [System.Net.Http.MultipartFormDataContent]::new()
        $Form.Add($FileContent, 'file', 'import.lucid')
        $Form.Add([System.Net.Http.StringContent]::new([string]$Title), 'title')
        $Form.Add([System.Net.Http.StringContent]::new([string]$Product), 'product')

        $HttpResponse = $HttpClient.PostAsync('https://api.lucid.co/documents', $Form).GetAwaiter().GetResult()
        $ResponseBody = $HttpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        if (!$HttpResponse.IsSuccessStatusCode) {
            throw ('Lucid document import failed with status ' + [int]$HttpResponse.StatusCode + ': ' + $ResponseBody)
        }

        return ($ResponseBody | ConvertFrom-Json)
    }
    finally {
        if ($Form) { $Form.Dispose() }
        $HttpClient.Dispose()
        Remove-Item -Path $PackagePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-ARILucidAccessToken {
    Param($TokenCachePath)

    if ([string]::IsNullOrEmpty($TokenCachePath)) {
        $TokenCachePath = Join-Path $HOME '.ari/lucid_token_cache.json'
    }

    if (!(Test-Path -Path $TokenCachePath)) {
        throw ('No cached Lucid credentials found at ' + $TokenCachePath + '. Run Connect-ARILucidAccount once to authorize this app before calling Export-ARILucidDiagram.')
    }

    $Cache = Get-Content -Path $TokenCachePath -Raw | ConvertFrom-Json

    $Body = @{
        grant_type    = 'refresh_token'
        refresh_token = $Cache.RefreshToken
        client_id     = $Cache.ClientId
        client_secret = $Cache.ClientSecret
    }

    try {
        $TokenResponse = Invoke-RestMethod -Uri 'https://api.lucid.co/oauth2/token' -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        throw ('Failed to refresh Lucid access token: ' + $_.Exception.Message)
    }

    if ($TokenResponse.refresh_token) {
        $Cache.RefreshToken = $TokenResponse.refresh_token
        $Cache | ConvertTo-Json | Out-File -FilePath $TokenCachePath -Encoding utf8
    }

    return $TokenResponse.access_token
}

function Connect-ARILucidAccount {
    <#
    .SYNOPSIS
    One-time interactive authorization against Lucid's OAuth2 app, caching a refresh token for later unattended use by Export-ARILucidDiagram.

    .DESCRIPTION
    Lucid's REST API documents the OAuth2 authorization_code grant, not a pure server-to-server
    client_credentials flow, so this requires one interactive browser sign-in per app registration.
    Call it once with only -ClientId/-ClientSecret to get the authorization URL; open that URL, sign
    in, and copy the "code" query string value from the redirect. Then re-run this function with
    -AuthorizationCode to exchange it for tokens and cache the refresh token.

    .PARAMETER ClientId
    Client ID of the OAuth2 app registered in Lucid's developer portal (Admin > API in your Lucid account).

    .PARAMETER ClientSecret
    Client secret of the same OAuth2 app.

    .PARAMETER RedirectUri
    Redirect URI configured on the OAuth2 app. Must match exactly.

    .PARAMETER Scope
    OAuth2 scopes to request. Defaults to document content access plus offline_access (required to receive a refresh token). Confirm the exact scope names your app needs against the scopes configured for it in the Lucid developer portal.

    .PARAMETER AuthorizationCode
    The "code" value from the redirect URL, after completing sign-in at the authorization URL this function prints when called without it.

    .PARAMETER TokenCachePath
    Where to persist the refresh token. Defaults to ~/.ari/lucid_token_cache.json.

    .EXAMPLE
    Connect-ARILucidAccount -ClientId <id> -ClientSecret <secret>
    # -> prints an authorization URL to open in a browser

    Connect-ARILucidAccount -ClientId <id> -ClientSecret <secret> -AuthorizationCode <code-from-redirect>
    # -> exchanges the code for tokens and caches the refresh token
    #>
    Param(
        [Parameter(Mandatory = $true)]
        $ClientId,
        [Parameter(Mandatory = $true)]
        $ClientSecret,
        $RedirectUri = 'https://localhost/callback',
        $Scope = 'lucidchart.document.content offline_access',
        $AuthorizationCode,
        $TokenCachePath
    )

    if ([string]::IsNullOrEmpty($TokenCachePath)) {
        $TokenCachePath = Join-Path $HOME '.ari/lucid_token_cache.json'
    }

    if ([string]::IsNullOrEmpty($AuthorizationCode)) {
        $AuthUrl = 'https://lucid.app/oauth2/authorize?' + (
            @(
                'response_type=code',
                ('client_id=' + [uri]::EscapeDataString([string]$ClientId)),
                ('redirect_uri=' + [uri]::EscapeDataString([string]$RedirectUri)),
                ('scope=' + [uri]::EscapeDataString([string]$Scope))
            ) -join '&'
        )

        Write-Output 'No -AuthorizationCode supplied. Open this URL, sign in, then re-run this command with -AuthorizationCode set to the "code" value from the redirect:'
        Write-Output $AuthUrl
        return
    }

    $Body = @{
        grant_type    = 'authorization_code'
        code          = $AuthorizationCode
        client_id     = $ClientId
        client_secret = $ClientSecret
        redirect_uri  = $RedirectUri
    }

    try {
        $TokenResponse = Invoke-RestMethod -Uri 'https://api.lucid.co/oauth2/token' -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        throw ('Failed to exchange Lucid authorization code for tokens: ' + $_.Exception.Message)
    }

    $CacheDir = Split-Path -Path $TokenCachePath -Parent
    if (!(Test-Path -Path $CacheDir)) {
        New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    }

    @{
        ClientId     = $ClientId
        ClientSecret = $ClientSecret
        RefreshToken = $TokenResponse.refresh_token
    } | ConvertTo-Json | Out-File -FilePath $TokenCachePath -Encoding utf8

    Write-Output ('Lucid refresh token cached at: ' + $TokenCachePath)
}

function Export-ARILucidDiagram {
    <#
    .SYNOPSIS
    Exports a Lucid network topology diagram built from a resource cache saved by Invoke-ARI -SaveResourceCache.

    .DESCRIPTION
    Reads the JSON resource cache, builds a VNet/subnet/gateway network graph, converts it into a
    Lucid Standard Import (.lucid) package, and uploads it via the Lucid REST API. Requires a
    one-time Connect-ARILucidAccount authorization before first use.

    .PARAMETER CacheFolder
    Folder containing resources.json/subscriptions.json produced by Invoke-ARI -SaveResourceCache.

    .PARAMETER ReportName
    Title given to the created Lucid document. Defaults to 'AzureResourceInventory'.

    .PARAMETER Product
    Lucid product to create the document in: 'lucidchart' (default) or 'lucidspark'.

    .PARAMETER TokenCachePath
    Path to the cached Lucid OAuth credentials written by Connect-ARILucidAccount. Defaults to ~/.ari/lucid_token_cache.json.

    .EXAMPLE
    Export-ARILucidDiagram -CacheFolder 'C:\AzureResourceInventory\DiagramCache' -ReportName 'Contoso Network'
    #>
    Param(
        [Parameter(Mandatory = $true)]
        $CacheFolder,
        $ReportName = 'AzureResourceInventory',
        [ValidateSet('lucidchart', 'lucidspark')]
        $Product = 'lucidchart',
        $TokenCachePath
    )

    if (!(Test-Path -Path $CacheFolder)) {
        throw ('Cache folder not found: ' + $CacheFolder + '. Run Invoke-ARI -SaveResourceCache first.')
    }

    Write-Output 'Loading resource cache...'
    $Graph = Get-ARILucidNetworkGraph -CacheFolder $CacheFolder

    Write-Output ('Building network graph for ' + [string]$Graph.AZVNETs.Count + ' Virtual Network(s)...')
    $Document = Build-ARILucidDocument -Graph $Graph -PageTitle ($ReportName + ' - Network Topology')

    Write-Output 'Packaging Standard Import file...'
    $PackagePath = New-ARILucidImportPackage -Document $Document

    Write-Output 'Requesting Lucid access token...'
    $AccessToken = Get-ARILucidAccessToken -TokenCachePath $TokenCachePath

    Write-Output 'Uploading diagram to Lucid...'
    $Result = Send-ARILucidImport -PackagePath $PackagePath -AccessToken $AccessToken -Title ($ReportName + ' - Network Topology') -Product $Product

    Write-Output ('Lucid document created: ' + $Result.editUrl)

    return $Result
}
