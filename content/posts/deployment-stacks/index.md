---
author: Dylan Prins
title: "Smaller Azure deployments with deployment stacks"
date: 2026-11-16T12:28:00+01:00
description: Share outputs between Azure deployment stacks to deploy only what changed and keep ARM templates within the 4 MB limit.
tags:
    - Azure
    - Bicep
    - Deployment Stacks
    - Platform Engineering
draft: true
---

One Bicep deployment for your network, shared services, and workloads is easy to manage at first. As the environment grows, a small workload change still runs through the deployment process for the whole environment. Eventually, the template may hit ARM's 4 MB limit.

Separate stacks let you update a workload without redeploying its network. To do that, the workload needs the subnet ID from the network stack.

We'll pass deployment outputs, such as resource IDs and names, between stacks. This doesn't copy databases or files or transfer ownership of resources.

## What is a deployment stack?

An Azure deployment stack is a resource of type `Microsoft.Resources/deploymentStacks`. You supply a Bicep or ARM template, and the stack tracks the resources it manages.

When you update a stack, `actionOnUnmanage` determines what happens to resources that are no longer in the template:

- `detachAll`: leave the resources in place, but stop managing them through the stack.
- `deleteResources`: delete resources that are no longer managed.
- `deleteAll`: also delete resource groups that are no longer managed.

You can also use deny settings to restrict updates or deletions outside the stack. ARM still handles the deployment itself.

ARM limits still apply to stacks. Deployment-time savings depend on how you split the infrastructure and whether your pipeline skips components that haven't changed.

## Split by lifecycle

For a platform with several workloads, you could use these boundaries:

| Stack | Manages | Changes when |
| --- | --- | --- |
| Network | VNet and subnets | Network configuration changes |
| Shared services | Shared platform resources | A platform service changes |
| Workload | Resources for one application | That application's infrastructure changes |

Deploy each stack through its own entrypoint. You can use Bicep modules within those entrypoints, but a main template with many local modules still produces one deployment request containing the module templates. Passing the subnet ID as a parameter keeps the network deployment out of the workload template.

## Example: passing a subnet ID

This example uses two resource-group-scoped stacks in the same subscription and resource group. The network stack manages a VNet and subnet. The workload stack manages a network interface that uses that subnet.

You'll need a recent Azure CLI with `az stack` and Bicep support, an existing resource group, and a signed-in identity with the necessary deployment, stack, and resource permissions. Reading outputs also requires read access to the source stack. The example uses Azure public cloud.

### 1. Publish an output from the network stack

Save this as `network.bicep`:

```bicep
targetScope = 'resourceGroup'

param location string = resourceGroup().location

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-platform'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: '10.20.1.0/24'
        }
      }
    ]
  }
}

output subnetId string = '${vnet.id}/subnets/workloads'
```

Deploy the network stack:

```bash
set -euo pipefail

resourceGroup='rg-stack-demo'

az stack group create \
  --name network \
  --resource-group "$resourceGroup" \
  --template-file network.bicep \
  --action-on-unmanage detachAll \
  --deny-settings-mode none
```

In this example, `detachAll` prevents a resource from being deleted just because you removed it from the template. It doesn't protect resources that remain in the template from being changed. `none` disables stack deny protection. Review both settings before using this approach in production.

### 2. Read the output after a successful deployment

The stack stores its deployment outputs. Reading `properties.outputs.subnetId.value` through the REST API avoids differences in how CLI versions present stack properties.

Run this in the same Bash session, after the network deployment has completed successfully:

```bash
subscriptionId="$(az account show --query id --output tsv)"
stackId="/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Resources/deploymentStacks/network"

subnetId="$(az rest \
  --method get \
  --url "https://management.azure.com${stackId}?api-version=2024-03-01" \
  --query 'properties.outputs.subnetId.value' \
  --output tsv)"

if [[ -z "$subnetId" || "$subnetId" == "null" || "$subnetId" == "None" ]]; then
  printf '%s\n' 'The network stack has no usable subnetId output.' >&2
  exit 1
fi
```

Check the subscription, scope, and stack name before reading the output. If the source deployment fails, stop the dependent deployment so it can't use outputs left over from an earlier deployment.

### 3. Pass the value to the workload stack

Save this as `workload.bicep`:

```bicep
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param subnetId string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: 'nic-workload-demo'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
  }
}
```

Deploy the second stack with the value you retrieved:

```bash
az stack group create \
  --name workload-demo \
  --resource-group "$resourceGroup" \
  --template-file workload.bicep \
  --parameters subnetId="$subnetId" \
  --action-on-unmanage detachAll \
  --deny-settings-mode none
```

The workload template uses the subnet ID without managing the subnet or including a network module. Your pipeline must order the two deployments. A `dependsOn` within a template doesn't establish dependencies between separate pipeline jobs.

## Where the deployment-time savings come from

On the first rollout, the network stack must finish before the workload stack starts. For later changes:

1. Deploy the network stack when its template, parameters, or modules change.
2. Read the outputs of the successfully deployed network stack when deploying a workload.
3. Deploy only the workload stacks affected by the change.
4. Run independent workload deployments in parallel where their dependencies allow it.

You can read outputs from an unchanged source stack without redeploying it. Schedule periodic drift checks and reconciliation as well; a pipeline that only reacts to source changes won't catch changes made outside it.

Measure total pipeline time before and after the split. Slow resource providers, throttling, and additional stack calls can limit the savings.

## Keeping within ARM's 4 MB limit

Microsoft documents a maximum of 4 MB per ARM template and 1 MB per resource definition. A parameter file is also limited to 4 MB. The template limits apply after expansion of iterative resource definitions and parameter and variable values. A deployment request can therefore be too large even when the source file is smaller than 4 MB.

Deploying the network and workloads separately keeps their infrastructure definitions out of the same request. Pass small outputs such as IDs instead of entire network objects or large configuration arrays.

When checking deployment sizes:

- Every stack deployment must remain within the applicable ARM limits.
- Local Bicep modules improve structure but don't guarantee a smaller main request.
- Linked templates offer different options from inline nested templates, but don't remove all deployment limits.
- Check the generated ARM template and expansion during deployment, rather than relying on the size of the Bicep source file.

## Treat outputs as an interface

An output name such as `subnetId` becomes an interface between teams and pipelines. Coordinate changes with its consumers before removing or renaming it. If the subnet ID itself changes, check which workloads need to be redeployed.

Publish only non-secret values. Keep passwords, tokens, and connection strings out of ordinary outputs, pipeline artifacts, and logs. Use Key Vault and managed identities where appropriate.

Avoid circular dependencies, and don't have multiple stacks manage the same resource. Sharing a resource ID doesn't transfer ownership. When splitting existing infrastructure, handle ownership as a separate migration: deliberately detach resources from the old stack before the new stack takes over, review deny settings, and guard against accidental deletion.

Database and storage migrations need their own plan for replication, backups, and cutover. Passing stack outputs doesn't move application data.

## Choosing your stack boundaries

Group resources that change together and expose the values other stacks need. In this example, passing the subnet ID lets the workload deploy independently once the network exists.

Have the pipeline deploy only the affected stacks, then compare request sizes and pipeline timings with the original deployment. The split needs to reduce the work ARM handles on each run to be worth maintaining.

## References

- [Deployment stacks in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks)
- [ARM template best practices and limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits)
- [Deployment Stacks: Get at Resource Group](https://learn.microsoft.com/en-us/rest/api/resources/deployment-stacks/get-at-resource-group?view=rest-resources-2024-03-01)
- [Linked and nested templates](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/linked-templates)
- [Bicep outputs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/outputs)
