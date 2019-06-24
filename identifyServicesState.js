'use strict';

var db = require('bhendi').db;
var cassandra = require('bhendi').cassandra;

const webhookState = {
    ONLINE: 'online',
    OFFLINE: 'offline_configured',
    OFFLINE_RESYNC: 'offline_resync',
    ONLINECONFIGURED: 'online_configured'
};

const etcdEvents =  {
    SYNCHRONIZE: 'synchronize',
    SNAPSHOT: 'snapshot',
    RETRY: 'retry',
    CLEANUP: 'cleanup',
    RECONFIGURE: 'reconfigure',
    POLICY_UPGRADE: 'policy-upgrade',
    HEARTBEAT: 'heartbeat'
};


async function getBadGatewayStates() {
    console.log('entry:: getGatewayStates:: Get the gateway state as per webhook');
    try {
        await db.connect();
        let gatewayServices = await db.list(null, 'apim.gateway_service');
        let configuredGatewayServices = await db.list(null, 'apim.configured_gateway_service') ;
        let allGatewayServices = gatewayServices.results.concat(configuredGatewayServices.results);
        let onlineGatewayService = [];
        let offlineGatewayService = [];
        let offlineResyncGatewayService = [];
        let onlineConfigured = [];

        for(let gw of allGatewayServices) {
            let webhookURL = gw.webhook_url;
            if(gw.catalog_webhook_url) {
                webhookURL = gw.catalog_webhook_url;
            }

            let webhookTmpArray = webhookURL.split('/');
            let webhook = await db.get(null, 'apim.webhook', 'id = ? allow filtering', [ webhookTmpArray[webhookTmpArray.length -1] ]);
            if(!webhook) {
                continue;
            }

            gw.webhook = webhook;

            switch (webhook.state) {
                case webhookState.ONLINECONFIGURED:
                    onlineConfigured.push(gw);
                    break;
                case webhookState.ONLINE :
                    onlineGatewayService.push(gw);
                    break;
                case webhookState.OFFLINE :
                    offlineGatewayService.push(gw);
                    break;
                case webhookState.OFFLINE_RESYNC :
                    offlineResyncGatewayService.push(gw);
                    break;
            }
        }

        return {
            'online' : onlineGatewayService,
            'offline_configured' : offlineGatewayService,
            'offline_resync' : offlineResyncGatewayService,
            'online_configured' : onlineConfigured
        };

    } catch(err) {

    }

    console.log('exit:: getGatewayStates');
}


async function getBadPortalStates() {
    console.log('entry:: getBadPortalStates:: Get the portal state as per webhook');
    try {
        await db.connect();
        let portalServices = await db.list(null, 'apim.portal_service');
        let catalogSettings = await db.list(null, 'apim.catalog_setting') ;
        let allPortalWebhookUrls = [];

        for (let portalService of portalServices.results) {
            allPortalWebhookUrls.push(portalService.webhook_url);
        }

        for (let catalogSetting of catalogSettings.results) {
            if(catalogSetting.portal && catalogSetting.portal.webhook_url) {
                allPortalWebhookUrls.push(catalogSetting.portal.webhook_url);
            }
        }

        let onlinePortalService = [];
        let offlinePortalService = [];
        let offlineResyncPortalService = [];
        let onlineConfigured = [];

        for(let portalWebhookUrl of allPortalWebhookUrls) {

            let webhookTmpArray = portalWebhookUrl.split('/');
            let webhook = await db.get(null, 'apim.webhook', 'id = ? allow filtering', [ webhookTmpArray[webhookTmpArray.length -1] ], ['state']);
            if(!webhook) {
                continue;
            }

            switch (webhook.state) {
                case webhookState.ONLINECONFIGURED:
                    onlineConfigured.push(portalWebhookUrl);
                    break;
                case webhookState.ONLINE :
                    onlinePortalService.push(portalWebhookUrl);
                    break;
                case webhookState.OFFLINE :
                    offlinePortalService.push(portalWebhookUrl);
                    break;
                case webhookState.OFFLINE_RESYNC :
                    offlineResyncPortalService.push(portalWebhookUrl);
                    break;
            }
        }

        return {
            'online' : onlinePortalService,
            'offline_configured' : offlinePortalService,
            'offline_resync' : offlineResyncPortalService,
            'online_configured' : onlineConfigured
        };

    } catch(err) {

    }

    console.log('exit:: getBadPortalStates');
}


async function getUniqueTaskStuckByState(service, taskState) {
    let taskTypes = [ etcdEvents.SYNCHRONIZE, etcdEvents.RECONFIGURE ];
    let state  = taskState || 'inprogress';
    let subsystemTasks = [];

    for(let taskType of taskTypes) {
        let taskQueueQuery = 'SELECT * FROM apim.task_queue_orderbystatetime WHERE namespace = \'cloud\' AND state = \'' +
            state + '\' AND kind = \'' + taskType + '\'';
        let tasks = await cassandra.eachRowAsync(taskQueueQuery, [], 16, async function(body) {
            let jsonBody = body.payload;
            let subsystem;
            try {
                let parsedPayload = JSON.parse(JSON.parse(jsonBody));
                if(parsedPayload.webhook) {
                    if(parsedPayload.webhook.gateway_service_url) {
                        subsystem = parsedPayload.webhook.gateway_service_url;
                    } else if(parsedPayload.webhook.portal_service_url) {
                        subsystem = parsedPayload.webhook.url;
                    }
                } else  {
                    subsystem = parsedPayload.gateway_service.url;
                }
            } catch (e) {

            }

            if(subsystem && subsystem === service) {
                subsystemTasks.push(body.id);
            }
        });
    }

    if(subsystemTasks.length > 0) {
        return subsystemTasks[0];
    } else {
        return null;
    }
}

// Don't use this function until required to renew the task on support.
async function fixWebhookTask(taskid) {
    console.log('Fixing task' + taskid);
    try {
        await db.connect();
        let taskTables = [ 'apim.task_queue', 'apim.task_queue_by_id', 'apim.task_queue_by_ns_name', 'apim.task_queue_orderbystatetime' ];

        // fetch the task and reinsert the same task value with state new
        let task = await db.get(null, 'apim.task_queue_by_id', 'id = ?', [ taskid ]);

        if(task === undefined || task === null) {
            console.log('No such task found for taskid:' + taskid);
        }

        for(let taskTable of taskTables) {
            // Get the table metadata for keys
            let tableMetadata = await db.getMetadata(taskTable);
            let keys = '';
            let values = [];
            for (let key of tableMetadata.partitionKeys.concat(tableMetadata.clusteringKeys)) {
                if(keys.length !== 0) {
                    keys = keys + ' and ';
                }

                keys = keys + key.name + ' = ?';
                values.push(task[key.name].toString());
            }

            await cassandra.del(taskTable, keys, values);
            task.state = 'new';
            task.id =  task.id.toString();
            task.generated_at = task.generated_at.toString();
            console.log(JSON.stringify(task));
            await cassandra.insertRaw(taskTable, task)
        }


    } catch (e) {
        console.log('Exception occurred while fixing task');
        throw e;
    }

    console.log('Fixing task completed');
}


async function driver() {
    console.log('entry:: driver');
    let gatewayInfo = await getBadGatewayStates();

    console.log('\nGWS generic information: ' + JSON.stringify(gatewayInfo));

    console.log('\n Identifying the pending task for broken gateway \n');

    let undesiredWebhookStates = [ webhookState.ONLINE, webhookState.OFFLINE, webhookState.OFFLINE_RESYNC ];
    let taskStates = [ 'inprogress', 'claimed', 'scheduled', 'new', 'errored', 'failed' ];

    for (let undesiredWebhookState of undesiredWebhookStates) {
        for(let gw of gatewayInfo[ undesiredWebhookState ]) {
            let task;
            let taskState;
            for(taskState of taskStates) {
                task = await getUniqueTaskStuckByState(gw.url, taskState);
                if(task) {
                    break;
                }
            }

            let statement = 'Identified the task for gw: ' + gw.url + ' state: ' + undesiredWebhookState;
            if(gw.webhook && gw.webhook.state_updated_at) {
                statement+=' state changed at: '+ gw.webhook.state_updated_at;
            }


            if(task) {
                statement += ' task id: ' + task + ' task state:' + taskState;
                console.log('\n' + statement);
            } else {
                console.log('\n'+ statement +' No task found');
            }

        }
    }

    let portalInfo = await getBadPortalStates();

    console.log('\nPortal generic information: ' + JSON.stringify(portalInfo));

    console.log('\n Identifying the pending task for broken portal \n');

    for (let undesiredWebhookState of undesiredWebhookStates) {
        for(let portalUrl of portalInfo[ undesiredWebhookState ]) {
            let task;
            let taskState;
            for(taskState of taskStates) {
                task = await getUniqueTaskStuckByState(portalUrl, taskState);
                if(task) {
                    break;
                }
            }

            if (task) {
                console.log('\n Identified the task for portal webhook: ' + portalUrl + ' state: ' + undesiredWebhookState + ' task id: ' + task + ' task state:' + taskState);
            } else {
                console.log('\n Identified the task for portal webhook: ' + portalUrl + ' state: ' + undesiredWebhookState + ' No task found');
            }

        }
    }

    console.log('\n exit:: driver');
}


driver().then(() => {
    process.exit(0);
}).catch((err) => {
    console.log(err);
    process.exit(1);
});
