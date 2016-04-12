#!/bin/sh
readonly CERTSDIR=/etc/kubernetes/ssl
readonly HELPERS_DIR=/tmp/kube-helpers
readonly MANIFESTS_DIR=/tmp/kube-manifests
readonly KNOWN_TOKENS_FILE="/srv/kubernetes/known_tokens.csv"
readonly BASIC_AUTH_FILE="/srv/kubernetes/basic_auth.csv"

sudo chown root:root /etc/kubernetes/ssl/*.pem && \
sudo chown root:root /etc/ssl/etcd/*.pem && \
chmod +x /opt/bin/kubectl && \
chmod +x /opt/bin/kubelet-wrapper && \
mkdir -p /home/core/.kube && \
ln -s /etc/kubernetes/kube.conf /home/core/.kube/config && \
sudo systemctl daemon-reload && \
sudo systemctl enable kubelet && \
sudo systemctl start kubelet && \
sudo systemctl enable kube-apiserver && \
sudo systemctl start kube-apiserver

function mount-master-pd() {
  if [[ ! -e /dev/disk/by-id/google-master-pd ]]; then
    echo "/dev/disk/by-id/google-master-pd not found"
    return
  fi

  device_info=$(ls -l /dev/disk/by-id/google-master-pd)
  relative_path=${device_info##* }
  device_path="/dev/disk/by-id/${relative_path}"

  # Format and mount the disk, create directories on it for all of the master's
  # persistent data, and link them to where they're used.
  echo "Mounting master-pd"
  mkdir -p /mnt/master-pd
  safe_format_and_mount=${HELPERS_DIR}/safe_format_and_mount
  chmod +x ${safe_format_and_mount}
  ${safe_format_and_mount} -m "mkfs.ext4 -F" "${device_path}" \
/mnt/master-pd &>/var/log/master-pd-mount.log || \
{ echo "!!! master-pd mount failed, review /var/log/master-pd-mount.log !!!"; return 1; }

  # Contains all the data stored in etcd
  mkdir -m 700 -p /mnt/master-pd/var/etcd
  # Contains the dynamically generated apiserver auth certs and keys
  mkdir -p /mnt/master-pd/srv/kubernetes
  # Directory for kube-apiserver to store SSH key (if necessary)
  mkdir -p /mnt/master-pd/srv/sshproxy

  ln -s -f /mnt/master-pd/f /var/etcd
  ln -s -f /mnt/master-pd/srv/kubernetes /srv/kubernetes
  ln -s -f /mnt/master-pd/srv/sshproxy /srv/sshproxy

  if ! id etcd &>/dev/null; then
    useradd -s /sbin/nologin -d /var/etcd etcd
  fi
  chown -R etcd /mnt/master-pd/var/etcd
  chgrp -R etcd /mnt/master-pd/var/etcd
}

# function create-salt-master-auth() {
  # if [[ ! -e /srv/kubernetes/ca.crt ]]; then
  #   if [[ ! -z "${CA_CERT:-}" ]] && [[ ! -z "${MASTER_CERT:-}" ]] && [[ ! -z "${MASTER_KEY:-}" ]]; then
  #     echo "Creating TLS assets in /srv/kubernetes"
  #     mkdir -p /srv/kubernetes
  #     (umask 077;
  #       echo "${CA_CERT}" | base64 -d > /srv/kubernetes/ca.crt;
  #       echo "${MASTER_CERT}" | base64 -d > /srv/kubernetes/server.cert;
  #       echo "${MASTER_KEY}" | base64 -d > /srv/kubernetes/server.key;
  #       # Kubecfg cert/key are optional and included for backwards compatibility.
  #       # TODO(roberthbailey): Remove these two lines once GKE no longer requires
  #       # fetching clients certs from the master VM.
  #       echo "${KUBECFG_CERT:-}" | base64 -d > /srv/kubernetes/kubecfg.crt;
  #       echo "${KUBECFG_KEY:-}" | base64 -d > /srv/kubernetes/kubecfg.key)
  #   fi
  # fi
  # if [ ! -e "${BASIC_AUTH_FILE}" ]; then
  #   mkdir -p /srv/kubernetes
  #   (umask 077;
  #     echo "${KUBE_PASSWORD},${KUBE_USER},admin" > "${BASIC_AUTH_FILE}")
  # fi
  # if [ ! -e "${KNOWN_TOKENS_FILE}" ]; then
  #   mkdir -p /srv/kubernetes
  #   (umask 077;
  #     echo "${KUBE_BEARER_TOKEN},admin,admin" > "${KNOWN_TOKENS_FILE}";
  #     echo "${KUBELET_TOKEN},kubelet,kubelet" >> "${KNOWN_TOKENS_FILE}";
  #     echo "${KUBE_PROXY_TOKEN},kube_proxy,kube_proxy" >> "${KNOWN_TOKENS_FILE}")
  #
  #   # Generate tokens for other "service accounts".  Append to known_tokens.
  #   #
  #   # NB: If this list ever changes, this script actually has to
  #   # change to detect the existence of this file, kill any deleted
  #   # old tokens and add any new tokens (to handle the upgrade case).
  #   local -r service_accounts=("system:scheduler" "system:controller_manager" "system:logging" "system:monitoring")
  #   for account in "${service_accounts[@]}"; do
  #     token=$(dd if=/dev/urandom bs=128 count=1 2>/dev/null | base64 | tr -d "=+/" | dd bs=32 count=1 2>/dev/null)
  #     echo "${token},${account},${account}" >> "${KNOWN_TOKENS_FILE}"
  #   done
  # fi
# }

function load-master-components-images() {
  echo "Loading docker images for master components"
  ${SALT_DIR}/install.sh ${KUBE_BIN_TAR}
  ${SALT_DIR}/salt/kube-master-addons/kube-master-addons.sh

  # Get the image tags.
  KUBE_APISERVER_DOCKER_TAG=$(cat ${KUBE_BIN_DIR}/kube-apiserver.docker_tag)
  KUBE_CONTROLLER_MANAGER_DOCKER_TAG=$(cat ${KUBE_BIN_DIR}/kube-controller-manager.docker_tag)
  KUBE_SCHEDULER_DOCKER_TAG=$(cat ${KUBE_BIN_DIR}/kube-scheduler.docker_tag)
}

function configure-master-components() {
  configure-admission-controls
  configure-etcd
  configure-etcd-events
  configure-kube-apiserver
  configure-kube-scheduler
  configure-kube-controller-manager
  configure-master-addons
}

function configure-admission-controls() {
  echo "Configuring admission controls"
  mkdir -p /etc/kubernetes/admission-controls
  cp -r ${HELPERS_DIR}/limit-range /etc/kubernetes/admission-controls/
}

function configure-etcd() {
  echo "Configuring etcd"
  touch /var/log/etcd.log
  evaluate-manifest ${MANIFESTS_DIR}/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
}

function configure-etcd-events() {
  echo "Configuring etcd-events"
  touch /var/log/etcd-events.log
  evaluate-manifest ${MANIFESTS_DIR}/etcd-events.yaml /etc/kubernetes/manifests/etcd-events.yaml
}

function evaluate-manifest() {
  local src=$1
  local dst=$2
  cp ${src} ${dst}
  sed -i 's/\"/\\\"/g' ${dst} # eval will remove the double quotes if they are not escaped
  eval "echo \"$(< ${dst})\"" > ${dst}
}

# evaluate-manifests-dir evalutes the source manifests within $1 and put the result
# in $2.
function evaluate-manifests-dir() {
  local src=$1
  local dst=$2
  mkdir -p ${dst}

  for f in ${src}/*
  do
    evaluate-manifest $f ${dst}/${f##*/}
  done
}

function configure-kube-apiserver() {
  echo "Configuring kube-apiserver"

  # Wait for etcd to be up.
  wait-url-up http://127.0.0.1:4001/version

  touch /var/log/kube-apiserver.log

  evaluate-manifest ${MANIFESTS_DIR}/kube-apiserver.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
}

function configure-kube-scheduler() {
  echo "Configuring kube-scheduler"
  touch /var/log/kube-scheduler.log
  evaluate-manifest ${MANIFESTS_DIR}/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
}

function configure-kube-controller-manager() {
  # Wait for api server.
  wait-url-up http://127.0.0.1:8080/version
  echo "Configuring kube-controller-manager"
  touch /var/log/kube-controller-manager.log
  evaluate-manifest ${MANIFESTS_DIR}/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml
}

# Wait until $1 become reachable.
function wait-url-up() {
  until curl --silent $1
  do
    sleep 5
  done
}

function configure-master-addons() {
  echo "Configuring master addons"

  local addon_dir=/etc/kubernetes/addons
  mkdir -p ${addon_dir}

  # Copy namespace.yaml
  evaluate-manifest ${MANIFESTS_DIR}/addons/namespace.yaml ${addon_dir}/namespace.yaml

  if [[ "${ENABLE_L7_LOADBALANCING}" == "glbc" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/cluster-loadbalancing/glbc ${addon_dir}/cluster-loadbalancing/glbc
  fi

  if [[ "${ENABLE_CLUSTER_DNS}" == "true" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/dns ${addon_dir}/dns
  fi

  if [[ "${ENABLE_CLUSTER_UI}" == "true" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/dashboard ${addon_dir}/dashboard
  fi

  if [[ "${ENABLE_CLUSTER_MONITORING}" == "influxdb" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/cluster-monitoring/influxdb  ${addon_dir}/cluster-monitoring/influxdb
  elif [[ "${ENABLE_CLUSTER_MONITORING}" == "google" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/cluster-monitoring/google  ${addon_dir}/cluster-monitoring/google
  elif [[ "${ENABLE_CLUSTER_MONITORING}" == "standalone" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/cluster-monitoring/standalone  ${addon_dir}/cluster-monitoring/standalone
  elif [[ "${ENABLE_CLUSTER_MONITORING}" == "googleinfluxdb" ]]; then
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/cluster-monitoring/googleinfluxdb  ${addon_dir}/cluster-monitoring/googleinfluxdb
  fi

  # Note that, KUBE_ENABLE_INSECURE_REGISTRY is not supported yet.
  if [[ "${ENABLE_CLUSTER_REGISTRY}" == "true" ]]; then
    CLUSTER_REGISTRY_DISK_SIZE=$(convert-bytes-gce-kube "${CLUSTER_REGISTRY_DISK_SIZE}")
    evaluate-manifests-dir ${MANIFESTS_DIR}/addons/registry  ${addon_dir}/registry
  fi
}

function configure-logging() {
  echo "Configuring fluentd-gcp"
  # fluentd-gcp
  evaluate-manifest ${MANIFESTS_DIR}/addons/fluentd-gcp/fluentd-gcp.yaml /etc/kubernetes/manifests/fluentd-gcp.yaml
}

mount-master-pd
# create-salt-master-auth
load-master-components-images
configure-master-components
configure-logging
