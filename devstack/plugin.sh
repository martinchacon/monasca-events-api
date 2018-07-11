#!/bin/bash

#
# Copyright 2017 FUJITSU LIMITED
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Save trace setting
_EVENTS_XTRACE=$(set +o | grep xtrace)
set -o xtrace
_EVENTS_ERREXIT=$(set +o | grep errexit)
set -o errexit

# source lib/*
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/utils.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/zookeeper.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/kafka.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/elasticsearch.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/events-persister.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/events-api.sh
source ${MONASCA_EVENTS_API_DIR}/devstack/lib/events-agent.sh

# Files inside this directory will be visible in gates log
GATE_CONFIGURATION_DIR=/etc/monasca-events-api

ES_SERVICE_BIND_HOST=${ES_SERVICE_BIND_HOST:-${SERVICE_HOST}}
ES_SERVICE_BIND_PORT=${ES_SERVICE_BIND_PORT:-9200}
ES_SERVICE_PUBLISH_HOST=${ES_SERVICE_PUBLISH_HOST:-${SERVICE_HOST}}
ES_SERVICE_PUBLISH_PORT=${ES_SERVICE_PUBLISH_PORT:-9300}

KIBANA_DIR=$DEST/kibana
KIBANA_CFG_DIR=$KIBANA_DIR/config
KIBANA_SERVICE_HOST=${KIBANA_SERVICE_HOST:-${SERVICE_HOST}}
KIBANA_SERVICE_PORT=${KIBANA_SERVICE_PORT:-5601}
KIBANA_SERVER_BASE_PATH=${KIBANA_SERVER_BASE_PATH:-"/dashboard/monitoring/logs_proxy"}
PLUGIN_FILES=$MONASCA_EVENTS_API_DIR/devstack/files


function install_node_nvm {
    set -i
    if [[ ! -f "${HOME}/.nvm/nvm.sh" ]] && is_service_enabled kibana; then
        # note(trebskit) we need node to build kibana plugin
        # so if kibana is enabled in this environment, let's install node
        echo_summary "Install Node ${NODE_JS_VERSION} with NVM ${NVM_VERSION}"
        local nvmUrl=https://raw.githubusercontent.com/creationix/nvm/v${NVM_VERSION}/install.sh

        local nvmDest
        nvmDest=`get_extra_file ${nvmUrl}`

        bash ${nvmDest}
    fi
    if is_service_enabled kibana; then
        # refresh installation
        (
            source "${HOME}"/.nvm/nvm.sh >> /dev/null; \
            nvm install ${NODE_JS_VERSION}; \
            nvm use ${NODE_JS_VERSION}; \
            npm config set registry "http://registry.npmjs.org/"; \
            npm config set proxy "${HTTP_PROXY}"; \
            npm set strict-ssl false;
        )
    fi
    set +i
}


function install_kibana {
    if is_service_enabled kibana; then
        echo_summary "Installing Kibana ${KIBANA_VERSION}"

        local kibana_tarball=kibana-${KIBANA_VERSION}.tar.gz
        local kibana_tarball_url=http://download.elastic.co/kibana/kibana/${kibana_tarball}

        local kibana_tarball_dest
        kibana_tarball_dest=`get_extra_file ${kibana_tarball_url}`

        tar xzf ${kibana_tarball_dest} -C $DEST

        sudo chown -R $STACK_USER $DEST/kibana-${KIBANA_VERSION}
        ln -sf $DEST/kibana-${KIBANA_VERSION} $KIBANA_DIR
    fi
}

function configure_kibana {
    if is_service_enabled kibana; then
        echo_summary "Configuring Kibana ${KIBANA_VERSION}"

        sudo install -m 755 -d -o $STACK_USER $KIBANA_CFG_DIR

        sudo cp -f "${PLUGIN_FILES}"/kibana/kibana.yml $KIBANA_CFG_DIR/kibana.yml
        sudo chown -R $STACK_USER $KIBANA_CFG_DIR/kibana.yml
        sudo chmod 0644 $KIBANA_CFG_DIR/kibana.yml

        sudo sed -e "
            s|%KIBANA_SERVICE_HOST%|$KIBANA_SERVICE_HOST|g;
            s|%KIBANA_SERVICE_PORT%|$KIBANA_SERVICE_PORT|g;
            s|%KIBANA_SERVER_BASE_PATH%|$KIBANA_SERVER_BASE_PATH|g;
            s|%ES_SERVICE_BIND_HOST%|$ES_SERVICE_BIND_HOST|g;
            s|%ES_SERVICE_BIND_PORT%|$ES_SERVICE_BIND_PORT|g;
            s|%KEYSTONE_AUTH_URI%|$KEYSTONE_AUTH_URI|g;
        " -i $KIBANA_CFG_DIR/kibana.yml

        ln -sf $KIBANA_CFG_DIR/kibana.yml $GATE_CONFIGURATION_DIR/kibana.yml
    fi
}

function install_kibana_plugin {
    if is_service_enabled kibana; then
        echo_summary "Install Kibana plugin"

        # note(trebskit) that needs to happen after kibana received
        # its configuration otherwise the plugin fails to be installed

        local pkg=file://$DEST/monasca-kibana-plugin.tar.gz

        $KIBANA_DIR/bin/kibana plugin -r monasca-kibana-plugin
        $KIBANA_DIR/bin/kibana plugin -i monasca-kibana-plugin -u $pkg
    fi
}

function build_kibana_plugin {
    if is_service_enabled kibana; then
        echo "Building Kibana plugin"

        git_clone $MONASCA_KIBANA_PLUGIN_REPO $MONASCA_KIBANA_PLUGIN_DIR \
            $MONASCA_KIBANA_PLUGIN_BRANCH

        pushd $MONASCA_KIBANA_PLUGIN_DIR

        local monasca_kibana_plugin_version
        monasca_kibana_plugin_version="$(python -c 'import json; \
            obj = json.load(open("package.json")); print obj["version"]')"

        set -i
        (source "${HOME}"/.nvm/nvm.sh >> /dev/null; nvm use ${NODE_JS_VERSION}; npm install)
        (source "${HOME}"/.nvm/nvm.sh >> /dev/null; nvm use ${NODE_JS_VERSION}; npm run package)
        set +i

        local pkg=$MONASCA_KIBANA_PLUGIN_DIR/target/monasca-kibana-plugin-${monasca_kibana_plugin_version}.tar.gz
        local easyPkg=$DEST/monasca-kibana-plugin.tar.gz

        ln -sf $pkg $easyPkg

        popd
    fi
}

function start_kibana {
    if is_service_enabled kibana; then
        echo_summary "Starting Kibana ${KIBANA_VERSION}"
        local kibanaSleepTime=${KIBANA_SLEEP_TIME:-90}     # kibana takes some time to load up
        local kibanaCFG="$KIBANA_CFG_DIR/kibana.yml"
        run_process_sleep "kibana" "$KIBANA_DIR/bin/kibana --config $kibanaCFG" $kibanaSleepTime
    fi
}

function install_gate_config_holder {
    sudo install -d -o $STACK_USER $GATE_CONFIGURATION_DIR
}

function pre_install_monasca_events {
    echo_summary "Pre-Installing Monasca Events Dependency Components"

    find_nearest_apache_mirror
    install_zookeeper
    install_kafka
    install_elasticsearch
    install_kibana
    install_node_nvm
    install_gate_config_holder
}

function install_monasca_events {
    echo_summary "Installing Core Monasca Events Components"
    build_kibana_plugin
    install_events_persister
    install_events_api
    install_events_agent
}

function configure_monasca_events {
    echo_summary "Configuring Monasca Events Dependency Components"
    configure_zookeeper
    configure_kafka
    configure_elasticsearch
    configure_kibana
    install_kibana_plugin

    echo_summary "Configuring Monasca Events Core Components"
    configure_log_dir ${MONASCA_EVENTS_LOG_DIR}
    configure_events_persister
    configure_events_api
    configure_events_agent
}

function init_monasca_events {
    echo_summary "Initializing Monasca Events Components"
    start_zookeeper
    start_kafka
    start_elasticsearch
    start_kibana
    # wait for all services to start
    sleep 10s
    create_kafka_topic monevents
}

function start_monasca_events {
    echo_summary "Starting Monasca Events Components"
    start_events_persister
    start_events_api
    start_events_agent
}

function unstack_monasca_events {
    echo_summary "Unstacking Monasca Events Components"
    stop_events_agent
    stop_events_api
    stop_events_persister
    stop_elasticsearch
    stop_kafka
    stop_zookeeper
}

function clean_monasca_events {
    echo_summary "Cleaning Monasca Events Components"
    clean_events_agent
    clean_events_api
    clean_events_persister
    clean_elasticsearch
    clean_kafka
    clean_zookeeper
}

# check for service enabled
if is_service_enabled monasca-events; then

    if [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # Set up system services
        echo_summary "Configuring Monasca Events system services"
        pre_install_monasca_events

    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Perform installation of service source
        echo_summary "Installing Monasca Events"
        install_monasca_events

    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        # Configure after the other layer 1 and 2 services have been configured
        echo_summary "Configuring Monasca Events"
        configure_monasca_events

    elif [[ "$1" == "stack" && "$2" == "extra" ]]; then
        # Initialize and start the Monasca service
        echo_summary "Initializing Monasca Events"
        init_monasca_events
        start_monasca_events
    fi

    if [[ "$1" == "unstack" ]]; then
        # Shut down Monasca services
        echo_summary "Unstacking Monasca Events"
        unstack_monasca_events
    fi

    if [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        echo_summary "Cleaning Monasca Events"
        clean_monasca_events
    fi
fi

# Restore errexit & xtrace
${_EVENTS_ERREXIT}
${_EVENTS_XTRACE}
