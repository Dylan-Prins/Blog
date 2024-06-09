---
author: "Dylan Prins"
title: "That are not my resources, why should I have to pay for them!"
date: "2024-6-06"
description: "how you can move costs to other subscription to create internal charging"
tags: ["Cost Allocation", "Azure", "FinOps", "Platform Engineering"]
ShowToc: false
ShowBreadCrumbs: false
draft: true
---

## Introduction

## What is Cost allocation

In large enterprises, Azure services are often managed centrally but used by various departments. The central team usually wants to redistribute the cost of these shared services to the departments using them. This is where cost allocation in Azure's Cost Management comes in.

Cost allocation allows you to reassign the costs of shared services from one subscription, resource group, or tag to another within your organization. It's a way to shift the financial responsibility of shared services to the departments or business units that consume them, enhancing cost accountability.

However, it's important to note that cost allocation doesn't support purchases like reservations and savings plans. Also, it doesn't affect your billing invoice or change billing responsibilities. Its primary function is to facilitate internal chargebacks, showing costs as they are reassigned or distributed.

The allocated costs are visible in cost analysis, appearing as other items associated with the targeted subscriptions, resource groups, or tags specified in your cost allocation rule.

Reference: [Microsoft learn](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/allocate-costs)

## How to implement it

### Selecting your source

to select which costs should be allocated you have 3 options:

- Tags
- Resource Groups
- Subscriptions

Keep in mind if you choose Tags, even if you tag all the resources in a subscriptions, it is possible some costs will stay in the source subscription
like Defender for Cloud. When tags are used all the resources in your tenant with this tag will be selected.

![source](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/source.png)

### Selecting the destination

You have the same 3 options as destination, where tag is the strange one here.
I have not tested this one yet, but it looks weird to allocate cost to a tag.

![targets](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/targets.png)

### Distribute the selected costs

For distributing the costs you have multiple options. you can distribute the costs evenly or propotional to:

- compute costs
- network costs
- storage costs
- total costs

![distribute costs](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/distribute.png)

This function is only available in the portal. When you want to use the API to configure Cost allocation, you need to do the calculations yourself.
I have written a PowerShell function does this for you.

```powershell
function New-TargetResources {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]]$subscriptionId
  )

  begin {
    $TargetResources

    $percentage = 100 / $subscriptionId.count
  }

  process {
    foreach ($subscription in $subscriptionId) {
      $TargetResources += @{
        name         = 'SubscriptionId'
        policyType   = 'FixedProportion'
        resourceType = 'Dimension'
        values       = @(
          @{
            name       = $subscription
            percentage = $percentage
          }
        )
      }
    }
  }

  end {
    $TargetResources
  }
}
```

## Usecases

### Shared AKS

If you use a shared AKS cluster it is possible that you have multiple teams working on different nodepools with different sku's.
If thats the case you want to allocate the costs of that specific nodepool to the right team.

![aks-case](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/aks-use-case.png)

#### Step 1: Tag all the node pools

Every node pool should be tagged to, so that it is clear which spoke it belongs to.
In my case I used 1 tag containing an Identifier of the workload and the environment like this `wrkld-prod`.

#### Step 2: Create a Cost Allocation rule

Create a Cost allocation rule with as source the tag for the spoke and distribute 100% to the corresponding subscription.
The tag can now be used for other for other services as well. just tag the specific resource and it will rearrange the costs to the subscription.

### Azure Firewall

When you have an Hub/spoke network model in Azure, you will most likely have a central firewall in place where te traffic of your spoke is
going through. Cost allocation makes it possible to rearrange the cost of the subscription of the firewall to all the spokes.

![firewall-case](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/firewall-use-case.png)

#### Step 1: Retrieve all the spokes

Retrieve all the spokes that you want to allocate the firewall cost to. I used the PowerShell commandlet `Get-AzManagementGroupSubscription`
to get all the subscriptions ID's.

#### Step 2: Create the target objects

You can use the PowerShell function above to distribute the costs evenly over all the subscriptions.
If you want the costs to distribute proportional to the network costs, you can do this step in the portal or retrieve information from the billing API.

## Limitations

- You cannot order the rules. the rules are executed in creation order.
- There is a function to allocate costs with propotional to network or compute cost, but this function is only available in the portal and not with the API.
- Target subscriptions is limited to 200. This means if you have a lot of spokes you should consider only allocate to production subscriptions.

## References

- [Microsoft learn](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/allocate-costs)
- [Rest API](https://learn.microsoft.com/en-us/rest/api/cost-management/cost-allocation-rules?view=rest-cost-management-2023-11-01)
