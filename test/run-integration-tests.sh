#!/bin/bash
#
# Description:
#   This script runs all Weave Net's integration tests on the specified
#   provider (default: Google Cloud Platform).
#
# Usage:
#
#   Run all integration tests on Google Cloud Platform:
#   $ ./run-integration-tests.sh
#
#   Run all integration tests on Amazon Web Services:
#   PROVIDER=aws ./run-integration-tests.sh
#

DIR="$(dirname "$0")"
. "$DIR/../tools/provisioning/config.sh" # Import set_up_for_gcp, set_up_for_do and set_up_for_aws.
. "$DIR/config.sh" # Import greenly.

# Variables:
PROVIDER=${PROVIDER:-gcp}  # Provision using provided provider, or Google Cloud Platform by default.
NUM_HOSTS=${NUM_HOSTS:-10}
PLAYBOOK=${PLAYBOOK:-setup_docker_k8s_weave-kube.yml}
TESTS=${TESTS:-}
RUNNER_ARGS=${RUNNER_ARGS:-""}
# Dependencies' versions:
DOCKER_VERSION=${DOCKER_VERSION:-1.11.2}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.5.1}
KUBERNETES_CNI_VERSION=${KUBERNETES_CNI_VERSION:-0.3.0.1}
# Lifecycle flags:
SKIP_CREATE=${SKIP_CREATE:-}
SKIP_CONFIG=${SKIP_CONFIG:-}
SKIP_DESTROY=${SKIP_DESTROY:-}

function print_vars() {
  echo "--- Variables: Main ---"
  echo "PROVIDER=$PROVIDER"
  echo "NUM_HOSTS=$NUM_HOSTS"
  echo "PLAYBOOK=$PLAYBOOK"
  echo "TESTS=$TESTS"
  echo "RUNNER_ARGS=$RUNNER_ARGS"
  echo "--- Variables: Versions ---"
  echo "DOCKER_VERSION=$DOCKER_VERSION"
  echo "KUBERNETES_VERSION=$KUBERNETES_VERSION"
  echo "KUBERNETES_CNI_VERSION=$KUBERNETES_CNI_VERSION"
  echo "--- Variables: Flags ---"
  echo "SKIP_CREATE=$SKIP_CREATE"
  echo "SKIP_CONFIG=$SKIP_CONFIG"
  echo "SKIP_DESTROY=$SKIP_DESTROY"
}

function verify_dependencies() {
  local deps=(python terraform ansible-playbook)
  for dep in "${deps[@]}"; do 
    if [ ! $(which $dep) ]; then 
      >&2 echo "$dep is not installed or not in PATH."
      exit 1
    fi
  done
}

function provision_locally() {
  case "$1" in
    on)
      vagrant up
      local status=$?
      eval $(vagrant ssh-config | sed \
        -ne 's/\ *HostName /ssh_hosts=/p' \
        -ne 's/\ *User /ssh_user=/p' \
        -ne 's/\ *Port /ssh_port=/p' \
        -ne 's/\ *IdentityFile /ssh_id_file=/p')
      return $status
      ;;
    off)
      vagrant destroy -f
      ;;
    *)
      >&2 echo "Unknown command $1. Usage: {on|off}."
      exit 1
      ;;
  esac
}

function provision_remotely() {
  case "$1" in
    on)
      terraform apply -input=false -parallelism="$NUM_HOSTS" -var "num_hosts=$NUM_HOSTS" "$DIR/../tools/provisioning/$2"
      local status=$?
      ssh_user=$(terraform output username)
      ssh_hosts=$(terraform output public_ips)
      return $status
      ;;
    off)
      terraform destroy -force "$DIR/../tools/provisioning/$2"
      ;;
    *)
      >&2 echo "Unknown command $1. Usage: {on|off}."
      exit 1
      ;;
  esac
}

function provision() {
  local action=$([ $1 == "on" ] && echo "Provisioning" || echo "Shutting down")
  echo; greenly echo "> $action test host(s) on [$PROVIDER]..."; local begin_prov=$(date +%s)
  case "$2" in
    aws)
      provision_remotely $1 $2
      ;;
    do)
      set_up_for_do
      provision_remotely $1 $2
      export ssh_id_file="$TF_VAR_do_private_key_path"
      ;;
    gcp)
      set_up_for_gcp
      provision_remotely $1 $2
      export ssh_id_file="$TF_VAR_gcp_private_key_path"
      ;;
    vagrant)
      provision_locally $1
      ;;
    *)
      >&2 echo "Unknown provider $2. Usage: PROVIDER={gcp|aws|do|vagrant}."
      exit 1
      ;;
  esac
  echo; greenly echo "> Provisioning took $(date -u -d @$(($(date +%s)-$begin_prov)) +"%T")."
}

function configure() {
  echo; greenly echo "> Configuring test host(s)..."; local begin_conf=$(date +%s)
  local inventory_file=$(mktemp /tmp/ansible_inventory_XXXXX)
  echo "[all]" > "$inventory_file"
  echo "$2" | sed 's/,//' | sed "s/$/:$3/" >> "$inventory_file"
  local ssh_extra_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  local playbook="$DIR/../tools/config_management/$PLAYBOOK"

  ansible-playbook -u "$1" -i "$inventory_file" --private-key="$4" --forks="$NUM_HOSTS" \
    --ssh-extra-args="$ssh_extra_args" \
    --extra-vars "docker_version=$DOCKER_VERSION kubernetes_version=$KUBERNETES_VERSION kubernetes_cni_version=$KUBERNETES_CNI_VERSION" \
    "$playbook"

  echo; greenly echo "> Configuration took $(date -u -d @$(($(date +%s)-$begin_conf)) +"%T")."
}

function run_all() {
  echo; greenly echo "> Running tests..."; local begin_tests=$(date +%s)
  export SSH="ssh -l $1 -i $2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  export COVERAGE=""
  export HOSTS="$(echo "$3" | sed 's/,//' | tr '\n' ' ')"
  shift 3 # Drop the first 3 arguments, the remainder being, optionally, the list of tests to run.
  "$DIR/setup.sh"
  set +e
  "$DIR/run_all.sh" $@
  local status=$?
  echo; greenly echo "> Tests took $(date -u -d @$(($(date +%s)-$begin_tests)) +"%T")."
  return $status
}

begin=$(date +%s)
print_vars
verify_dependencies

provision on $PROVIDER
if [ $? -ne 0 ]; then
  >&2 echo "> Failed to provision test host(s)."
  exit 1
fi

if [ "$SKIP_CONFIG" != "yes" ]; then
  configure $ssh_user "$ssh_hosts" ${ssh_port:-22} $ssh_id_file
  if [ $? -ne 0 ]; then
    >&2 echo "Failed to configure test host(s)."
    exit 1
  fi
fi

run_all $ssh_user $ssh_id_file "$ssh_hosts" "$TESTS"
status=$?

if [ "$SKIP_DESTROY" != "yes" ]; then
  provision off $PROVIDER
fi

echo; greenly echo "> Build took $(date -u -d @$(($(date +%s)-$begin)) +"%T")."
exit $status
