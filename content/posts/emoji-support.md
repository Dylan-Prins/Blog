---
author: "Dylan Prins"
title: "Done with secret renewal in Azure DevOps? use Workload identity!"
date: "2024-01-04"
description: ""
tags: ["Workload Identity", "Azure DevOps", "App registrations", "Platform Engineering"]
ShowToc: false
ShowBreadCrumbs: false
---

## Introduction

With most Enterprise environments we use a lot of service connections. Before Workload identity you had 2 options, secrets or certificates.
While certificates is a fine option, most still use secrets. Secrets have an expiry date with a maximum of 2 years.
If you want to lean more about how Workload identity works, you can check the Microsoft learn page [here](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation).

## Migrating to Workload identity

To migrate to Workload identity I wrote a PowerShell script that searches for service connection within a list of Azure DevOps projects that has the type set to AzureRM (This way we only update service connections that are using Azure). Then it will update the service connection to use Workload identity and recieves the Issuer and Subject that is needed to configure the App Registration. Then it will update the App Registration and test if the service connection works.

In the end you get a list with service connections where you can see the results of all the tests.

```powershell
#Requires -Modules @{ ModuleName="AzureDevOpsPowerShell"; ModuleVersion="0.2.2" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Applications"; ModuleVersion="2.11.1" }

<#
.SYNOPSIS
  Convert a service principal to use workload identity federation
.DESCRIPTION
  This script will convert a service principal to use workload identity federation.
  It will update the service connection to use workload identity federation and create the workload identity federation credentials.
  It will also test the service connection.
.NOTES
  This script requires the:
  - Microsoft.Graph.Applications module to be installed.
  - AzureDevOpsPowerShell module to be installed.
  - Api permission (one of the following): Application.ReadWrite.OwnedBy, Application.ReadWrite.All or Directory.ReadWrite.All
  - Azure Devops permissions (one of the following): Endpoint Administrators, Project Administrators, project Collection Administrators or Project Collection Service Accounts
.EXAMPLE
  Test-MyTestFunction -Verbose
  Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>

[cmdletbinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    # The collection uri of the Azure DevOps organization
    [parameter(Mandatory)]
    [string]
    $CollectionUri,

    # An array of project names to update service connections for
    [parameter(Mandatory)]
    [string[]]
    $Projects
)

$result = @()

foreach ($projectName in $Projects) {

    Clear-AzDoAuthHeader
    $serviceConnections = Get-AzDoServiceConnection -CollectionUri $CollectionUri -ProjectName $projectName

    foreach ($serviceConnection in $serviceConnections) {

        if (($serviceConnection.ServiceConnectionAuthorization.scheme -ne 'WorkloadIdentityFederation') -and ($serviceConnection.ServiceConnectionType -eq 'azurerm')) {
            # update service connection to use workload identity federation

            $body = @{
                name                             = $serviceConnection.ServiceConnectionName
                type                             = $serviceConnection.ServiceConnectionType
                description                      = $serviceConnection.ServiceConnectionDescription
                url                              = $serviceConnection.ServiceConnectionUrl
                data                             = $serviceConnection.ServiceConnectionData
                serviceEndpointProjectReferences = $serviceConnection.ServiceConnectionServiceEndpointProjectReferences
                authorization                    = @{
                    parameters = @{
                        tenantid           = $serviceConnection.ServiceConnectionAuthorization.parameters.tenantid
                        serviceprincipalid = $serviceConnection.ServiceConnectionAuthorization.parameters.serviceprincipalid
                    }
                    scheme     = 'WorkloadIdentityFederation'
                }
            }

            $params = @{
                Uri         = "$CollectionUri/$ProjectName/_apis/serviceendpoint/endpoints/$($serviceConnection.ServiceConnectionId)?api-version=7.2-preview.4"
                Method      = 'PUT'
                Headers     = @{Authorization = 'Bearer ' + (Get-AzAccessToken -Resource 499b84ac-1321-427f-aa17-267ca6975798).token }
                ContentType = 'application/json'
                Body        = $body | ConvertTo-Json -Depth 10
            }

            if ($PSCmdlet.ShouldProcess($ProjectName, "Update service connection: $($serviceConnection.ServiceConnectionName)")) {
                Invoke-RestMethod @params | Out-Null

                # get updated service connection for the issuer and subject
                $updatedServiceConn = Get-AzDoServiceConnection -ServiceConnectionName $serviceConnection.ServiceConnectionName -ProjectName $projectName -CollectionUri $collectionUri

                # create workload identity federation credentials
                Connect-MgGraph -AccessToken ((Get-AzAccessToken -ResourceTypeName MSGraph).token | ConvertTo-SecureString -AsPlainText -Force) -NoWelcome

                $app = Get-MgApplicationByAppId -AppId $updatedServiceConn.ServiceConnectionAuthorization.parameters.serviceprincipalid

                $params = @{
                    name      = "AzureDevOps-$projectName"
                    issuer    = $updatedServiceConn.ServiceConnectionAuthorization.parameters.workloadIdentityFederationIssuer
                    subject   = $updatedServiceConn.ServiceConnectionAuthorization.parameters.workloadIdentityFederationSubject
                    audiences = @(
                        "api://AzureADTokenExchange"
                    )
                }

                New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $params

                #test service connection
                $test = Test-AzDoServiceConnection -ServiceConnectionName $updatedServiceConn.ServiceConnectionName -ProjectName $projectName -CollectionUri $collectionUri

                $result += [PSCustomObject]@{
                    ProjectName           = $ProjectName
                    ServiceConnectionName = $updatedServiceConn.ServiceConnectionName
                    Issuer                = $updatedServiceConn.ServiceConnectionAuthorization.parameters.workloadIdentityFederationIssuer
                    Subject               = $updatedServiceConn.ServiceConnectionAuthorization.parameters.workloadIdentityFederationSubject
                    State                 = $test.result -match 'is working as expected' ? 'Success' : 'Failed'
                }
            }
        }
    }
}

$result | Format-Table
```

## Creating App registrations

When working with landing zone you want to automate the setup for creating the subscription, Azure DevOps, etc. Thats why I also created
a script to creates a App Registration from scratch instead of converting an existing one.

```powershell
#Requires -Modules @{ ModuleName="Microsoft.Graph.Applications"; ModuleVersion="2.11.1" }

<#
.SYNOPSIS
  A script to create an app registration, service principal and credential for Azure DevOps
.DESCRIPTION
  This script will create an app registration, service principal and credential for Azure DevOps. Could be used in your automation to create landing zones
.NOTES
  This script requires the:
  - Microsoft.Graph.Applications module to be installed.
  - Api permission (one of the following): Application.ReadWrite.OwnedBy, Application.ReadWrite.All or Directory.ReadWrite.All
.EXAMPLE
  Test-MyTestFunction -Verbose
  Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>

[CmdletBinding()]
param (
    # Name of the app registration
    [Parameter(Mandatory)]
    [TypeName]
    $Name,

    # Issuer of the token
    [Parameter(Mandatory)]
    [TypeName]
    $Issuer,

    # Subject of the token
    [Parameter(Mandatory)]
    [TypeName]
    $Subject
)

# Create the app registration
$params = @{
  displayName = $Name
}

$app = New-MgApplication -BodyParameter $params

# Create the service principal
$params = @{
  appId = $app.AppId
}

New-MgServicePrincipal -BodyParameter $params

# Create the credential
$credentialName = $Subject.split("/")[-1]

$params = @{
  name      = "AzureDevOps-$credentialName"
  issuer    = $Issuer
  subject   = $Subject
  audiences = @(
    "api://AzureADTokenExchange"
  )
}

New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter $params

```
