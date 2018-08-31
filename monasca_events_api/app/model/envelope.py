# Copyright 2018 FUJITSU LIMITED
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

from oslo_utils import timeutils
import six

from monasca_common.rest import utils as rest_utils


def serialize_envelope(envelope):
    """Returns json representation of an envelope.

    :return: json object of envelope
    :rtype: six.text_type

    """
    json = rest_utils.as_json(envelope, ensure_ascii=False)

    if six.PY2:
        raw = unicode(json.replace(r'\\', r'\\\\'), encoding='utf-8',
                      errors='replace')
    else:
        raw = json

    return raw


class EventEnvelopeException(Exception):
    pass


class Envelope(dict):
    def __init__(self, event, meta):
        if not event:
            error_msg = 'Envelope cannot be created without event'
            raise EventEnvelopeException(error_msg)
        if 'tenantId' not in meta or not meta.get('tenantId'):
            error_msg = 'Envelope cannot be created without tenant'
            raise EventEnvelopeException(error_msg)

        creation_time = self._get_creation_time()
        super(Envelope, self).__init__(
            event=event,
            creation_time=creation_time,
            meta=meta
        )

    @staticmethod
    def _get_creation_time():
        return timeutils.utcnow_ts()

    @classmethod
    def new_envelope(cls, event, tenant_id, region, dimensions=None):
        """Creates new log envelope

        Log envelope is combined ouf of following properties

        * event - dict
        * creation_time - timestamp
        * meta - meta block

        Example output json would like this:

        .. code-block:: json

            {
                "event": {
                  "message": "Some message",
                  "dimensions": {
                    "hostname": "devstack"
                  }
                },
                "creation_time": 1447834886,
                "meta": {
                  "tenantId": "e4bd29509eda473092d32aadfee3e7b1",
                  "region": "pl"
                }
            }

        :param dict event: original event element
        :param str tenant_id: tenant id to be put in meta field
        :param str region: region to be put in meta field
        :param dict dimensions: additional dimensions to be appended to event
                                object dimensions

        """
        if dimensions:
            event['dimensions'].update(dimensions)

        event_meta = {
            'region': region,
            'tenantId': tenant_id
        }

        return cls(event, event_meta)

    @property
    def event(self):
        return self.get('event', None)

    @property
    def creation_time(self):
        return self.get('creation_time', None)

    @property
    def meta(self):
        return self.get('meta', None)

