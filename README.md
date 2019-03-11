# v2018-postmortem-tool

## Prerequisites
Place script in _apicup project_ directory or set the environment variable **APICUP_PROJECT_PATH** using the following command:
```
export APICUP_PROJECT_PATH="/path/to/directory"
```


## Instructions
### Kubernetes deployment:
1.  Make sure the **kubectl** command is installed and configured to the Kubernetes cluster.  See following commands to complete this task.
```
rm -fr $HOME/.kube
mkdir -p $HOME/.kube
scp root@{kubernetes_master_host}:/etc/kubernetes/admin.conf $HOME/.kube/config
```
2.  Move to **General** section.

### Instructions for OVA deployment:
1.  Make sure the **kubectl** command is installed and configured to the Kubernetes cluster.  See following commands to complete this task.
```
ssh apicadm@{ova appliance hostname}
sudo cp /etc/kubernetes/admin.conf $HOME/admin.conf
sudo chmod apicadm:apicadm $HOME/admin.conf
exit
rm -fr $HOME/.kube
mkdir -p $HOME/.kube
scp apicadm@{ova appliance hostname}:/home/apicadm/admin.conf $HOME/.kube/config
```
2.  By default, the kubernetes port is only exposed to the localhost.  To expose it to the current workstation, run the following commands:
```
ssh apicadm@{ova appliance hostname}
sudo -i
ssh -R 6444:localhost:6444 {current username}@{current workstation hostname / ip}
```
3.  Move to **General** section.

### General
1.  Make sure the **helm** command is installed, compatibile and connected (using `helm init`) with the Kubernetes cluster.
2.  Download the script to the _apicup project_ directory using the following command:
```
curl -o generate_postmortem.sh https://raw.githubusercontent.com/ibm-apiconnect/v2018-postmortem/master/generate_postmortem.sh
```
3.  Add execution permissions to file using the command `chmod +x generate_postmortem.sh`.
4.  Run the tool using the command `./generate_postmortem.sh` from the _apicup project_ directory.


## Need help?
-  Reach out on Slack in the channel **#v2018-postmortem-tool**
-  Open an issue to submit any feedback
-  Problem with the script?  Run the following command:
```
./generate_postmortem.sh --debug &>debug.log
```
then open an issue on the github page attaching the `debug.log` file.
