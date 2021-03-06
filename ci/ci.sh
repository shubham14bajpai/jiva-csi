#!/bin/bash

#set -ex

function initializeTestEnv() {
	echo "===================== Initialize test env ======================"
	# Pull image so that provisioning won't take long time
	docker pull openebs/jiva:ci
	cat <<EOT >> /tmp/parameters.json
{
        "cas-type": "jiva",
        "replicaCount": "1"
}
EOT
  sudo rm -rf /tmp/csi.sock
}


function dumpLogs() {
	echo "========================== Dump logs ==========================="
	local RESOURCE=$1
	local COMPONENT=$2
	local NS=$3
	local LABEL=$4
	local CONTAINER=$5
	local POD=$(kubectl get pod -n $NS -l $LABEL -o jsonpath='{range .items[*]}{@.metadata.name}')
	if [ -z $CONTAINER ];
	then
		kubectl logs --tail=50 $POD -n $NS
	else
		kubectl logs --tail=50 $POD -n $NS -c $CONTAINER
	fi
}

function dumpAllLogs() {
	echo "========================= Dump All logs ========================"
	kubectl get pods -n openebs
	kubectl describe pods -n openebs
	kubectl describe pods -n kube-system
	dumpLogs "ds" "openebs-jiva-csi-node" "kube-system" "app=openebs-jiva-csi-node" "openebs-jiva-csi-plugin"
	dumpLogs "sts" "openebs-jiva-csi-controller" "kube-system" "app=openebs-jiva-csi-controller" "openebs-jiva-csi-plugin"
	dumpLogs "deploy" "openebs-localpv-provisioner" "openebs" "name=openebs-localpv-provisioner"
}

function waitForComponent() {
	echo "====================== Wait for component ======================"
	local RESOURCE=$1
	local COMPONENT=$2
	local NS=$3
	local CONTAINER=$4
	local replicas=""

	for i in $(seq 1 50) ; do
		kubectl get $RESOURCE -n ${NS} ${COMPONENT}
		if [ "$RESOURCE" == "ds" ] || [ "$RESOURCE" == "daemonset" ];
		then
			replicas=$(kubectl get $RESOURCE -n ${NS} ${COMPONENT} -o json | jq ".status.numberReady")
		else
			replicas=$(kubectl get $RESOURCE -n ${NS} ${COMPONENT} -o json | jq ".status.readyReplicas")
		fi
		if [ "$replicas" == "1" ];
		then
			echo "${COMPONENT} is ready"
			break
		else
			echo "Waiting for ${COMPONENT} to be ready"
			if [ $i -eq "50" ];
			then
				dumpAllLogs
			fi
		fi
		sleep 10
	done
}

function initializeCSISanitySuite() {
	echo "=============== Initialize CSI Sanity test suite ==============="
	CSI_TEST_REPO=https://github.com/kubernetes-csi/csi-test.git
	CSI_REPO_PATH="$GOPATH/src/github.com/kubernetes-csi/csi-test"
	if [ ! -d "$CSI_REPO_PATH" ] ; then
		git clone $CSI_TEST_REPO $CSI_REPO_PATH
	else
		cd "$CSI_REPO_PATH"
		git pull $CSI_REPO_PATH
	fi

	cd "$CSI_REPO_PATH/cmd/csi-sanity"
	make clean
	make

	SOCK_PATH=/var/lib/kubelet/pods/`kubectl get pod -n kube-system openebs-jiva-csi-controller-0 -o 'jsonpath={.metadata.uid}'`/volumes/kubernetes.io~empty-dir/socket-dir/csi.sock
	sudo chmod -R 777 /var/lib/kubelet
	sudo ln -s $SOCK_PATH /tmp/csi.sock
	sudo chmod -R 777 /tmp/csi.sock
}

function waitForAllComponentsToBeReady() {
	waitForComponent "deploy" "openebs-ndm-operator" "openebs"
	waitForComponent "ds" "openebs-ndm" "openebs"
	waitForComponent "deploy" "openebs-localpv-provisioner" "openebs"
	waitForComponent "sts" "openebs-jiva-csi-controller" "kube-system" "openebs-jiva-csi-plugin"
	waitForComponent "ds" "openebs-jiva-csi-node" "kube-system" "openebs-jiva-csi-plugin"
}

function startTestSuite() {
	echo "================== Start csi-sanity test suite ================="
	./csi-sanity --ginkgo.v --csi.controllerendpoint=///tmp/csi.sock --csi.endpoint=/var/lib/kubelet/plugins/jiva.csi.openebs.io/csi.sock --csi.testvolumeparameters=/tmp/parameters.json
	if [ $? -ne 0 ];
	then
		dumpAllLogs
		exit 1
	fi
	exit 0
}

initializeTestEnv
waitForAllComponentsToBeReady
initializeCSISanitySuite
startTestSuite
