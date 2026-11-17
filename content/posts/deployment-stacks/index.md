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
draft: false
---

We used to deploy the entire subscription in one go. The network, shared services, and workloads all went through the same Bicep entrypoint. It was straightforward to follow: one deployment described the environment.

That became harder to maintain as the templates grew. We were using Azure Verified Modules (AVM), and combining those modules in a subscription-wide deployment brought us up against ARM's 4 MB template limit. The Bicep files could look manageable while the compiled template included the definitions of all those modules.

There was also the repeated work. Changing a workload meant submitting the whole environment again, including the network it depended on. Splitting the deployment into smaller stacks gave us a way to update those parts separately.

The next question was how to keep them connected. A workload still needs its subnet ID, even when the network belongs to another stack. I like to let Bicep read that value from the network stack, with the option to supply a subnet ID directly when using a different network.

We'll pass deployment outputs, such as resource IDs and names, between stacks.

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

Deploy each stack through its own entrypoint. You can use Bicep modules within those entrypoints, but a main template with many local modules still produces one deployment request containing the module templates. Reading the subnet ID from an existing stack keeps the network deployment out of the workload template.

## One resource group per stack

I use a dedicated resource group as the lifecycle boundary for each stack. When I retire a workload, I want to remove its resource group and everything inside it as well.

There is an important Azure scope distinction here: a resource-group-scoped stack doesn't manage its own containing resource group. Deleting that stack, even with `deleteAll`, won't automatically delete the containing group. To include the resource group in stack cleanup, the stack must be created at subscription scope and declare the resource group in its template, with the workload deployed into it through a module. With `deleteAll`, removing that stack also deletes the managed resource group and its contents.

Deleting a resource group also removes resources inside it that the stack doesn't track. That's why I keep the group dedicated to that stack and don't put unrelated resources there.

The output-sharing example below uses resource-group-scoped stacks to keep the Bicep files small. Each has its own resource group, but those groups are created separately and won't be deleted when the stacks are removed.

## Example: passing a subnet ID

This example uses two resource-group-scoped stacks in the same subscription, each in its own resource group. The `network` stack in `rg-network-demo` manages a VNet and subnet. The `workload-demo` stack in `rg-workload-demo` manages a network interface that uses that subnet.

You'll need a recent Azure CLI with `az stack` and Bicep support, both resource groups already created in the same region, and a signed-in identity with the necessary deployment, stack, and resource permissions. Reading outputs also requires read access to the source stack. The example uses Azure public cloud.

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
az stack group create \
  --name network \
  --resource-group rg-network-demo \
  --template-file network.bicep \
  --action-on-unmanage detachAll \
  --deny-settings-mode none
```

In this example, `detachAll` prevents a resource from being deleted just because you removed it from the template. It doesn't protect resources that remain in the template from being changed. `none` disables stack deny protection. Review both settings before using this approach in production.

### 2. Read the network stack or supply a subnet ID

The stack stores its deployment outputs. In the workload template, declare the network stack as an `existing` resource. I use `@nullIfNotFound()` so a missing stack evaluates to `null`, and safe access lets the template handle that result.

The optional `subnetId` parameter takes precedence. If it's omitted, Bicep reads the stack's output. This keeps the same workload template usable with either a stack-managed network or a subnet supplied by the caller, without a separate REST call or output-passing script.

Save this as `workload.bicep`:

```bicep
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param networkResourceGroupName string = 'rg-network-demo'
param networkStackName string = 'network'
param subnetId string?

@nullIfNotFound()
resource networkStack 'Microsoft.Resources/deploymentStacks@2024-03-01' existing = {
  name: networkStackName
  scope: resourceGroup(networkResourceGroupName)
}

var resolvedSubnetId = subnetId ?? networkStack.?properties.?outputs.?subnetId.?value

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
            id: resolvedSubnetId
          }
        }
      }
    ]
  }
}
```

The `existing` declaration only reads the network stack. It doesn't redeploy it or take ownership of its resources. When no subnet parameter is supplied, the stack needs to exist and expose the `subnetId` output.

Use a Bicep version that supports `@nullIfNotFound()`; this example was compiled with Bicep 0.49.2. The decorator handles a resource that isn't found, not missing read permissions. One source must supply a valid subnet ID. The final `''` is only a fallback for a missing value, not a usable subnet; passing an empty string explicitly also overrides the stack output.

Here, the source stack lives at resource group scope. For a subscription-scoped stack that manages a resource group as described above, use `scope: subscription()` in the existing declaration instead. The output expression stays the same.

### 3. Deploy the workload stack

```bash
az stack group create \
  --name workload-demo \
  --resource-group rg-workload-demo \
  --template-file workload.bicep \
  --action-on-unmanage detachAll \
  --deny-settings-mode none
```

To use a subnet supplied by the caller, add `--parameters subnetId='<full-subnet-resource-id>'` to that command. A non-null parameter overrides the stack output; leave it out to use the network stack.

The workload template uses the subnet without managing it or including a network module. All output lookup and consumption happens in Bicep; the CLI commands only submit the two stack deployments.

## Where the deployment-time savings come from

On the first rollout, the network stack must finish before the workload stack starts. For later changes:

1. Deploy the network stack when its template, parameters, or modules change.
2. Let the workload's Bicep template read the existing network stack's outputs.
3. Deploy only the workload stacks affected by the change.
4. Run independent workload deployments in parallel where their dependencies allow it.

You can read outputs from an unchanged source stack without redeploying it. Periodic drift checks and reconciliation still help catch changes made outside your templates.

Measure total pipeline time before and after the split. Slow resource providers, throttling, and additional stack calls can limit the savings.

## Keeping within ARM's 4 MB limit

Microsoft documents a maximum of 4 MB per ARM template and 1 MB per resource definition. A parameter file is also limited to 4 MB. The template limits apply after expansion of iterative resource definitions and parameter and variable values. A deployment request can therefore be too large even when the source file is smaller than 4 MB.

Deploying the network and workloads separately keeps their infrastructure definitions out of the same request. Pass small outputs such as IDs instead of entire network objects or large configuration arrays.

When checking deployment sizes:

- Every stack deployment must remain within the applicable ARM limits.
- Local Bicep modules improve structure but don't guarantee a smaller main request.
- Linked templates offer different options from inline nested templates, but don't remove all deployment limits.
- Check the generated ARM template and expansion during deployment, rather than relying on the size of the Bicep source file.

## Choosing your stack boundaries

Group resources that change together and expose the values other stacks need. In this example, the workload can read the network stack's output or use a subnet ID passed as a parameter.

Have the pipeline deploy only the affected stacks, then compare request sizes and pipeline timings with the original deployment. The split needs to reduce the work ARM handles on each run to be worth maintaining.

## References

- [Deployment stacks in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks)
- [ARM template best practices and limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits)
- [Reference existing resources in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/existing-resource)
- [The nullIfNotFound decorator](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/resource-declaration#nullifnotfound)
- [Linked and nested templates](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/linked-templates)
- [Bicep outputs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/outputs)
