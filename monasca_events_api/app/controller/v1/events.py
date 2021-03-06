# Copyright 2017 FUJITSU LIMITED
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

import falcon
from oslo_log import log
from voluptuous import MultipleInvalid

from monasca_events_api.app.common import helpers
from monasca_events_api.app.controller.v1 import body_validation
from monasca_events_api.app.controller.v1 import bulk_processor
from monasca_events_api.app.core.model import prepare_message_to_sent

LOG = log.getLogger(__name__)


class Events(object):
    """Events.

    Events acts as a RESTful endpoint accepting messages contains
    collected events from the OpenStack message bus.
    Works as getaway for any further processing for accepted data.
    """
    VERSION = 'v1.0'
    SUPPORTED_CONTENT_TYPES = {'application/json'}

    def __init__(self):
        super(Events, self).__init__()

        self._processor = bulk_processor.EventsBulkProcessor()

    def on_post(self, req, res):
        """Accepts sent events as json.

        Accepts events sent to resource which should be sent
        to Kafka queue.

        :param req: current request
        :param res: current response
        """
        policy_action = 'events_api:agent_required'

        try:
            request_body = helpers.read_json_msg_body(req)
            req.can(policy_action)
            body_validation.validate_body(request_body)
            messages = prepare_message_to_sent(request_body)
            self._processor.send_message(messages)
            res.status = falcon.HTTP_200
        except MultipleInvalid as ex:
            LOG.error('Entire bulk package was rejected, unsupported body')
            LOG.exception(ex)
            res.status = falcon.HTTP_422
        except Exception as ex:
            LOG.error('Entire bulk package was rejected')
            LOG.exception(ex)
            res.status = falcon.HTTP_400

    @property
    def version(self):
        return getattr(self, 'VERSION')
