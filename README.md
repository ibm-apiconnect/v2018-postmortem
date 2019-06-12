# v2018-postmortem-tool


## Instructions
### OVA deployment:
1. Connect to the target appliance via SSH then switch to the _root user_ using the following commands:
```
ssh apicadm@{ova appliance hostname}
sudo -i
```
2.  Download the script using the following command:
```
curl -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
3.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
4.  Run the tool using the command `./generate_postmortem.sh --ova`.

### Kubernetes deployment:
------
#### Prerequisites
Place script in _apicup project_ directory or set the environment variable **APICUP_PROJECT_PATH** using the following command:
```
export APICUP_PROJECT_PATH="/path/to/directory"
```
------
1.  Make sure the **kubectl** command is installed.
2.  Make sure the **kubectl** is configured to the Kubernetes cluster.  See following commands to complete this task.
```
rm -fr $HOME/.kube
mkdir -p $HOME/.kube
scp root@{kubernetes_master_host}:/etc/kubernetes/admin.conf $HOME/.kube/config
```
3.  Make sure the **helm** command is installed, compatibile and connected to the Kubernetes cluster.  See the following commands to complete this task.
```
rm -fr $HOME/.helm
curl -s https://raw.githubusercontent.com/helm/helm/master/scripts/get | bash -s -- --version v2.8.2
helm init --client-only
```
4.  Download the script to the _apicup project_ directory using the following command:
```
curl -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
5.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
6.  Run the tool using the command `./generate_postmortem.sh` from the _apicup project_ directory.


## Working a specific subystem issue?
Enable the following if troubleshooting an issue for the following subsystems:
### All (if requested by support)
`--diagnostic-all`
### Gateway
`--diagnostic-gateway`
### Portal
`--diagnostic-portal`


## Need help?
-  Reach out on Slack in the channel **#v2018-postmortem-tool**
-  Open an issue to submit any feedback
-  Problem with the script?  Run the following command:
```
./generate_postmortem.sh --debug &>debug.log
```
then open an issue on the github page attaching the `debug.log` file.