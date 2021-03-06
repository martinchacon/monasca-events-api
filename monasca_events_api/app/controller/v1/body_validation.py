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

import six

from oslo_log import log
from voluptuous import Any
from voluptuous import Required
from voluptuous import Schema


LOG = log.getLogger(__name__)


default_schema = Schema({Required("events"): Any(list, dict),
                         Required("timestamp"):
                             Any(str, unicode) if six.PY2 else str})


def validate_body(request_body):
    """Validate body.

     Method validate if body contain all required fields,
     and check if all value have correct type.


    :param request_body: body
    """
    default_schema(request_body)
