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

## How to Get Started with Cost Allocation

When it comes to cost allocation, the first step is deciding where your costs are coming from. You have three options to choose from:

- Tags
- Resource Groups
- Subscriptions

It's important to note that if you choose to use Tags, some costs may still remain in the source subscription, like Defender for Cloud, even if you tag all the resources in a subscription. When tags are used, all the resources in your tenant with this tag will be selected.

![source](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/source.png)

Next, you'll need to decide where these costs are going. Interestingly, you have the same three options as before. Allocating cost to a tag might seem a bit odd, and I haven't tested this one yet, but it's an option nonetheless.

![targets](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/targets.png)

Once you've selected your source and destination, it's time to decide how you want to distribute these costs. You have a few options here. You can choose to distribute the costs evenly or proportionally to:

- Compute costs
- Network costs
- Storage costs
- Total costs

![distribute costs](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/distribute.png)

This function is only available in the portal. If you're looking to use the API to configure Cost allocation, you'll need to do the calculations yourself. But don't worry, I've got you covered. I've written a handy PowerShell function that does this for you.

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

## Practical Applications of Cost Allocation

### Case Study: Shared AKS

Imagine you're using a shared AKS cluster. You have multiple teams, each working on different node pools with different SKUs. In this scenario, you'd want to allocate the costs of each specific node pool to the appropriate team.

![aks-case](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/aks-use-case.png)

#### Step 1: Tagging the Node Pools

The first step is to tag each node pool. This makes it clear which 'spoke' it belongs to. In my case, I used a single tag that included an identifier of the workload and the environment, like this: `wrkld-prod`.

#### Step 2: Creating a Cost Allocation Rule

Next, you'll want to create a Cost Allocation Rule. Use the tag for the spoke as the source and distribute 100% to the corresponding subscription. The beauty of this is that the tag can now be used for other services as well. Simply tag the specific resource and it will automatically rearrange the costs to the subscription.

### Case Study: Azure Firewall

If you're using a hub/spoke network model in Azure, chances are you have a central firewall in place where the traffic from your spoke is routed through. Cost allocation makes it possible to rearrange the cost from the subscription of the firewall to all the spokes.

![firewall-case](https://raw.githubusercontent.com/Dylan-Prins/Blog/main/content/posts/img/cost-allocation/firewall-use-case.png)

#### Step 1: Retrieving All the Spokes

First, you'll need to retrieve all the spokes that you want to allocate the firewall cost to. I used the PowerShell cmdlet `Get-AzManagementGroupSubscription` to get all the subscription IDs.

#### Step 2: Creating the Target Objects

You can use the PowerShell function above to distribute the costs evenly over all the subscriptions. If you want the costs to distribute proportionally to the network costs, you can do this step in the portal or retrieve information from the billing API.

## Limitations to Keep in Mind

There are a few limitations to keep in mind:

- You cannot order the rules. The rules are executed in the order they were created.
- There is a function to allocate costs proportionally to network or compute cost, but this function is only available in the portal and not with the API.
- Target subscriptions are limited to 200. This means if you have a lot of spokes, you should consider only allocating to production subscriptions.

## References

- [Microsoft learn](https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/allocate-costs)
- [Rest API](https://learn.microsoft.com/en-us/rest/api/cost-management/cost-allocation-rules?view=rest-cost-management-2023-11-01)
