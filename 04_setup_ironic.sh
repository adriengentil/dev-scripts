#!/bin/bash

set -ex

source logging.sh
source common.sh
source rhcos.sh

# Either pull or build the ironic images
# To build the IRONIC image set
# IRONIC_IMAGE=https://github.com/metalkube/metalkube-ironic
for IMAGE_VAR in IRONIC_IMAGE IRONIC_INSPECTOR_IMAGE IPA_DOWNLOADER_IMAGE COREOS_DOWNLOADER_IMAGE VBMC_IMAGE SUSHY_TOOLS_IMAGE; do
    IMAGE=${!IMAGE_VAR}
    # Is it a git repo?
    if [[ "$IMAGE" =~ "://" ]] ; then
        REPOPATH=~/${IMAGE##*/}
        # Clone to ~ if not there already
        [ -e "$REPOPATH" ] || git clone $IMAGE $REPOPATH
        cd $REPOPATH
        export $IMAGE_VAR=localhost/${IMAGE##*/}:latest
        sudo podman build -t ${!IMAGE_VAR} .
        cd -
    else
        sudo podman pull "$IMAGE"
    fi
done

for name in ironic ironic-api ironic-conductor ironic-inspector dnsmasq httpd mariadb ipa-downloader coreos-downloader vbmc sushy-tools; do
    sudo podman ps | grep -w "$name$" && sudo podman kill $name
    sudo podman ps --all | grep -w "$name$" && sudo podman rm $name -f
done

# Remove existing pod
if  sudo podman pod exists ironic-pod ; then 
    sudo podman pod rm ironic-pod -f
fi

# Create pod
sudo podman pod create -n ironic-pod 

# We start the httpd and *downloader containers so that we can provide
# cached images to the bootstrap VM
sudo podman run -d --net host --privileged --name httpd --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared --entrypoint /bin/runhttpd ${IRONIC_IMAGE}

sudo podman run -d --net host --privileged --name ipa-downloader --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared ${IPA_DOWNLOADER_IMAGE} /usr/local/bin/get-resource.sh

sudo podman run -d --net host --privileged --name coreos-downloader --pod ironic-pod \
     -v $IRONIC_DATA_DIR:/shared ${COREOS_DOWNLOADER_IMAGE} /usr/local/bin/get-resource.sh $RHCOS_IMAGE_URL

if [ "$NODES_PLATFORM" = "libvirt" ]; then
    sudo podman run -d --net host --privileged --name vbmc --pod ironic-pod \
         -v "$WORKING_DIR/virtualbmc/vbmc":/root/.vbmc -v "/root/.ssh":/root/ssh \
         "${VBMC_IMAGE}"
    
    sudo podman run -d --net host --privileged --name sushy-tools --pod ironic-pod \
         -v "$WORKING_DIR/virtualbmc/sushy-tools":/root/sushy -v "/root/.ssh":/root/ssh \
         "${SUSHY_TOOLS_IMAGE}"
fi


# Wait for the downloader containers to finish, if they are updating an existing cache
# the checks below will pass because old data exists
sudo podman wait -i 1000 ipa-downloader coreos-downloader

# Wait for images to be downloaded/ready
while ! curl --fail http://localhost/images/rhcos-ootpa-latest.qcow2.md5sum ; do sleep 1 ; done
while ! curl --fail --head http://localhost/images/ironic-python-agent.initramfs ; do sleep 1; done
while ! curl --fail --head http://localhost/images/ironic-python-agent.tar.headers ; do sleep 1; done
while ! curl --fail --head http://localhost/images/ironic-python-agent.kernel ; do sleep 1; done
