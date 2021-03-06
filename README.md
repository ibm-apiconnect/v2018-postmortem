# v2018-postmortem-tool

## Notes
- For usage information with the tool, use the command `./generate_postmortem.sh --help`

## Deployment Instructions
### OVA
1. Connect to the target appliance via SSH then switch to the _root user_ using the following commands:
```shell
ssh {ova appliance hostname} -l apicadm
sudo -i
```
2.  Download the script using the following command:
```shell
curl -s -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
3.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
4.  Run the tool using the command `./generate_postmortem.sh --ova`.

### Kubernetes / OpenShift
------
#### Prerequisites
Place script and run from the _apicup project_ directory  
-or-  
set the environment variable **APICUP_PROJECT_PATH** using the following command:
```shell
export APICUP_PROJECT_PATH="/path/to/directory"
```
------
1.  Download the script to the _apicup project_ directory using the following command:
```shell
curl -s -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
2.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
3.  Run the tool using the command `./generate_postmortem.sh` from the _apicup project_ directory.

### Cloud Pak 4i
1.  Download the script to the _apicup project_ directory using the following command:
```shell
curl -s -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
2.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
3.  Run the tool using the command `./generate_postmortem.sh --cp4i` from the _apicup project_ directory.


## Working a specific subystem issue?
Enable the following if troubleshooting an issue for the following subsystems:  
> **Note**: Enabling diagnostics may cause the script to take much longer to complete (especially over a VPN connection).
### All (if requested by support)
`--diagnostic-all`
### Manager
`--diagnostic-manager`  
> **Note**:  If internet not available on machine where script is executed, download `identifyServicesState.js` and place in same directory as `generate_postmortem.sh`.
### Gateway
`--diagnostic-gateway`
> **Note**: In order for this switch to function, make sure connections to `127.0.0.1` are not restricted on the local machine.
### Portal
`--diagnostic-portal`
### Analytics
`--diagnostic-analytics`


## Need help?
-  Open an issue to submit any feedback
-  Problem with the script?  Run the following command:
```shell
./generate_postmortem.sh --debug &>debug.log
```
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;then open an issue on the github page attaching the `debug.log` file.