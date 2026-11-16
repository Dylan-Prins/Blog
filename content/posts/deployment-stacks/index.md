---
author: Dylan Prins
title: "Kleinere Azure deployments met deployment stacks"
date: 2026-11-16T12:28:00+01:00
description: Deel outputs tussen deployment stacks om alleen gewijzigde onderdelen te deployen en grote ARM-templates te voorkomen.
tags:
    - Azure
    - Bicep
    - Deployment Stacks
    - Platform Engineering
draft: true
---

Een netwerk, gedeelde services en alle workloads in één Bicep-deployment: het begint overzichtelijk, maar kan uitgroeien tot een flinke template. Een kleine wijziging gaat dan door hetzelfde deploymentproces als de volledige omgeving. Uiteindelijk loop je misschien ook tegen de ARM-templatelimiet van 4 MB aan.

Deployment stacks kunnen helpen om je infrastructuur op te delen in onderdelen met een eigen lifecycle. Maar hoe gebruikt een workload dan het subnet dat een andere stack heeft aangemaakt?

In dit artikel betekent **data overhalen** het doorgeven van deploymentoutputs, zoals resource-ID's en namen. Het gaat niet om het kopiëren van databases of bestanden, en ook niet om het verplaatsen van resources tussen stacks.

## Wat is een deployment stack?

Een Azure deployment stack is een resource van het type `Microsoft.Resources/deploymentStacks`. Je levert een Bicep- of ARM-template aan en de stack houdt bij welke resources hij beheert.

Bij een update bepaalt `actionOnUnmanage` wat er gebeurt met resources die niet meer in de template staan:

- `detachAll`: de resources blijven bestaan, maar worden niet meer door de stack beheerd.
- `deleteResources`: verwijder de niet langer beheerde resources.
- `deleteAll`: verwijder ook niet langer beheerde resourcegroepen.

Daarnaast kun je deny settings gebruiken om wijzigingen of verwijderingen buiten de stack te beperken. Een stack is dus een beheerlaag rondom een deployment, geen alternatief voor de ARM-engine.

**Een stack maakt deployments niet automatisch sneller en verhoogt de ARM-limieten niet.** De winst komt uit de grenzen die je kiest en uit het niet opnieuw deployen van onderdelen die niet gewijzigd zijn.

## Splits op lifecycle, niet alleen op bestand

Een praktische verdeling is:

| Stack | Beheert | Wijzigt wanneer |
| --- | --- | --- |
| Network | VNet en subnets | De netwerkconfiguratie verandert |
| Shared services | Gedeelde platformresources | Een platformvoorziening verandert |
| Workload | Resources voor één applicatie | De infrastructuur van die applicatie verandert |

Elke stack heeft een eigen entrypoint en wordt afzonderlijk aangeroepen. Bicep-modules blijven handig **binnen** die entrypoints, maar één hoofdtemplate met veel lokale modules is nog steeds één deploymentrequest met daarin de moduletemplates.

Een workloaddeployment hoeft het netwerk niet opnieuw te deployen. Hij heeft alleen een klein contract nodig, bijvoorbeeld een subnet-ID.

## Voorbeeld: een subnet-ID doorgeven

We gebruiken twee resource-group-scoped stacks in dezelfde subscription en resourcegroep. De netwerkstack beheert een VNet met subnet; de workloadstack beheert een netwerkinterface die dat subnet gebruikt.

Je hebt een recente Azure CLI met `az stack` en Bicep-ondersteuning nodig, een bestaande resourcegroep en een ingelogde identiteit met de benodigde deployment-, stack- en resourcepermissies. Het lezen van stackoutputs vereist ook leesrechten op de bronstack. In dit voorbeeld gebruiken we Azure public cloud.

### 1. De netwerkstack publiceert een output

Sla dit op als `network.bicep`:

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

Deploy vervolgens de netwerkstack:

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

`detachAll` voorkomt in dit voorbeeld dat het weglaten van een resource uit de template meteen tot verwijdering leidt. Het is geen bescherming tegen wijzigingen aan resources die nog wél in de template staan. `none` schakelt stack-denybeveiliging uit; kies voor productie bewust je beheer- en beveiligingsinstellingen.

### 2. Lees de output na een succesvolle deployment

De stack bewaart de outputs van zijn deployment. Met de REST API lezen we expliciet `properties.outputs.subnetId.value`, zonder afhankelijk te zijn van de weergave van stackproperties in een CLI-versie.

Voer dit uit in dezelfde Bash-sessie, pas nadat de netwerkdeployment succesvol is afgerond:

```bash
subscriptionId="$(az account show --query id --output tsv)"
stackId="/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Resources/deploymentStacks/network"

subnetId="$(az rest \
  --method get \
  --url "https://management.azure.com${stackId}?api-version=2024-03-01" \
  --query 'properties.outputs.subnetId.value' \
  --output tsv)"

if [[ -z "$subnetId" || "$subnetId" == "null" || "$subnetId" == "None" ]]; then
  printf '%s\n' 'De netwerkstack heeft geen bruikbare subnetId-output.' >&2
  exit 1
fi
```

Gebruik altijd expliciet de juiste subscription, scope en stacknaam. Als een brondeployment faalt, laat de afhankelijke deployment dan niet doorgaan met eerder opgeslagen outputs.

### 3. De workloadstack ontvangt een parameter

Sla dit op als `workload.bicep`:

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

Deploy de tweede stack met de opgehaalde waarde:

```bash
az stack group create \
  --name workload-demo \
  --resource-group "$resourceGroup" \
  --template-file workload.bicep \
  --parameters subnetId="$subnetId" \
  --action-on-unmanage detachAll \
  --deny-settings-mode none
```

De workloadtemplate bevat geen netwerkmodule en beheert het subnet niet. Hij gebruikt alleen het ID. De volgorde tussen deze twee afzonderlijke deployments regel je in de pipeline; een `dependsOn` binnen één template doet dat niet voor losse pipelinejobs.

## Hoe verlaagt dit deploymenttijden?

Bij de eerste uitrol moet de netwerkstack klaar zijn voordat de workloadstack start. Bij latere wijzigingen kun je selectiever werken:

1. Deploy de netwerkstack alleen bij relevante wijzigingen aan zijn template, parameters of modules.
2. Lees voor een workloaddeployment de outputs van de succesvol uitgerolde netwerkstack.
3. Deploy alleen de gewijzigde workloadstack.
4. Laat onafhankelijke workloadstacks parallel draaien als hun afhankelijkheden dat toelaten.

Een ongewijzigde bronstack hoeft dus niet opnieuw uitgerold te worden om zijn output te gebruiken. Houd wel rekening met drift: plan periodieke controles en reconciliatie naast je wijzigingsgestuurde deployments.

Meet de totale pipelinetijd voor en na de splitsing. Trage resourceproviders, throttling en extra stackaanroepen kunnen de winst beperken. Er is geen gegarandeerde versnelling.

## En de ARM-limiet van 4 MB?

Microsoft documenteert een maximum van **4 MB per ARM-template** en **1 MB per resourcedefinitie**. Ook een parameterbestand is beperkt tot 4 MB. De limieten gelden voor de uiteindelijke template na uitbreiding van onder andere iteraties en parameter- en variabelewaarden. Een te groot deploymentrequest kan daarom ook problemen veroorzaken als je bronbestand kleiner is dan 4 MB.

Door het netwerk en de workloads als afzonderlijke deployments aan te bieden, hoeft niet alle infrastructuur in hetzelfde request mee. Geef kleine outputs door, geen volledig netwerkobject of enorme configuratiearrays.

Let op:

- Elke stackdeployment moet zelf nog steeds binnen de toepasselijke ARM-limieten blijven.
- Lokale Bicep-modules verbeteren de structuur, maar garanderen geen kleiner hoofdrequest.
- Linked templates hebben andere mogelijkheden dan inline nested templates, maar heffen niet alle deploymentlimieten op.
- Controleer niet alleen de grootte van je Bicep-bronbestand; kijk naar de gegenereerde ARM-template én naar uitbreiding tijdens deployment.

De oplossing is dus niet “een grote template in een stack stoppen”, maar **meerdere begrensde deployments met kleine interfaces maken**.

## Maak van outputs een stabiel contract

Een outputnaam zoals `subnetId` is een interface tussen teams en pipelines. Verwijder of hernoem die niet zonder de consumers mee te nemen. Bij een wijziging in het subnet-ID moet je ook beoordelen welke workloads opnieuw moeten worden uitgerold.

Publiceer alleen niet-geheime waarden. Wachtwoorden, tokens en connection strings horen niet in gewone outputs, pipeline-artifacts of logs. Gebruik daarvoor bijvoorbeeld Key Vault en managed identities.

Voorkom ook circulaire afhankelijkheden en laat dezelfde resource niet door meerdere stacks beheren. Het delen van een resource-ID draagt geen eigenaarschap over. Werk bij het opsplitsen van bestaande infrastructuur een aparte migratie uit: detach bewust vanuit de oude stack voordat de nieuwe stack het beheer overneemt, controleer deny settings en voorkom onbedoelde verwijdering.

Dit patroon verplaatst geen applicatiedata. Een database- of storage-migratie vraagt een afzonderlijk plan voor bijvoorbeeld replicatie, back-ups en de omschakeling.

## Conclusie

Deployment stacks geven je een duidelijke beheergrens. Door outputs als klein contract te gebruiken, kunnen andere stacks bestaande infrastructuur benutten zonder die opnieuw mee te deployen.

Daarmee maak je gerichte deployments mogelijk en verklein je de templates die ARM per deployment verwerkt. De belangrijkste ontwerpkeuze blijft: welke resources veranderen samen, en welke hoeven alleen elkaars ID te kennen?

## Referenties

- [Deployment stacks in Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deployment-stacks)
- [ARM-templatebest practices en limieten](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/best-practices#template-limits)
- [Deployment Stacks: Get at Resource Group](https://learn.microsoft.com/en-us/rest/api/resources/deployment-stacks/get-at-resource-group?view=rest-resources-2024-03-01)
- [Linked en nested templates](https://learn.microsoft.com/en-us/azure/azure-resource-manager/templates/linked-templates)
- [Bicep-outputs](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/outputs)
